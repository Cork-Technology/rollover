// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ICorkRolloverContractFactoryAdmin } from "src/interfaces/rollover/ICorkRolloverContractFactoryAdmin.sol";

/// @notice Curated source for the two deployment-provenance contracts included in the public release manifest.
/// @dev The operational DeployStaging script is intentionally not part of the public release.
/// @notice Canonical CREATE2 root interface used to establish the chain-invariant deployer.
interface IDeterministicDeploymentRoot {
    /// @notice Deploy `initCode` with `salt`.
    function deploy(bytes memory initCode, bytes32 salt) external returns (address payable deployed);
}

/// @title RolloverDeploymentBootstrap
/// @notice One-shot, repository-owned CREATE/CREATE2 coordinator used only to establish a fresh stack.
/// @dev The chain-neutral constructor makes this contract's CREATE2 address independent of deployment
///      configuration. The canonical deployer initializes all authority-bearing state atomically.
contract RolloverDeploymentBootstrap is Ownable {
    error Bootstrap__ConfigMismatch();
    error Bootstrap__DependencyMissing(address dependency);
    error Bootstrap__AddressMismatch(address actual, address expected);
    error Bootstrap__DeploymentFailed();
    error Bootstrap__RuntimeCodehashMismatch(address deployment, bytes32 actual, bytes32 expected);
    error Bootstrap__AlreadyFinalized();
    error Bootstrap__InvalidInitialization();
    error Bootstrap__AlreadyInitialized();

    bytes32 public CONFIG_HASH;
    bytes32 public DEPLOYMENT_ARTIFACTS_HASH;
    bool public initialized;
    bool public finalized;
    mapping(address deployment => bytes32 runtimeCodehash) public deployedCodehash;

    constructor() Ownable(msg.sender) { }

    /// @notice Atomically bind the deployment commitments and operational owner.
    /// @dev Only the canonical deployer that constructed this bootstrap can initialize it.
    function initialize(bytes32 configHash, bytes32 deploymentArtifactsHash, address initialOwner)
        external
        onlyOwner
    {
        if (initialized) {
            revert Bootstrap__AlreadyInitialized();
        }
        if (
            configHash == bytes32(0) || deploymentArtifactsHash == bytes32(0)
                || initialOwner == address(0)
        ) {
            revert Bootstrap__InvalidInitialization();
        }
        CONFIG_HASH = configHash;
        DEPLOYMENT_ARTIFACTS_HASH = deploymentArtifactsHash;
        initialized = true;
        _transferOwnership(initialOwner);
    }

    function deployCreate2(
        bytes32 configHash,
        bytes32 salt,
        bytes calldata initCode,
        address expected
    ) external onlyOwner returns (address deployed) {
        _checkConfig(configHash);
        if (expected.code.length != 0) {
            if (deployedCodehash[expected] != expected.codehash) {
                revert Bootstrap__AddressMismatch(expected, expected);
            }
            return expected;
        }
        bytes memory creationCode = initCode;
        assembly ("memory-safe") {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        if (deployed == address(0)) {
            revert Bootstrap__DeploymentFailed();
        }
        if (deployed != expected) {
            revert Bootstrap__AddressMismatch(deployed, expected);
        }
        deployedCodehash[deployed] = deployed.codehash;
    }

    function deployFactory(
        bytes32 configHash,
        bytes calldata initCode,
        address expected,
        bytes32 expectedRuntimeCodehash
    ) external onlyOwner returns (address deployed) {
        _checkConfig(configHash);
        if (expectedRuntimeCodehash == bytes32(0)) {
            revert Bootstrap__RuntimeCodehashMismatch(expected, bytes32(0), expectedRuntimeCodehash);
        }
        if (expected.code.length != 0) {
            if (
                expected.codehash != expectedRuntimeCodehash
                    || deployedCodehash[expected] != expectedRuntimeCodehash
            ) {
                revert Bootstrap__RuntimeCodehashMismatch(
                    expected, expected.codehash, expectedRuntimeCodehash
                );
            }
            return expected;
        }
        bytes memory creationCode = initCode;
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        if (deployed == address(0)) {
            revert Bootstrap__DeploymentFailed();
        }
        if (deployed != expected) {
            revert Bootstrap__AddressMismatch(deployed, expected);
        }
        if (deployed.codehash != expectedRuntimeCodehash) {
            revert Bootstrap__RuntimeCodehashMismatch(
                deployed, deployed.codehash, expectedRuntimeCodehash
            );
        }
        deployedCodehash[deployed] = expectedRuntimeCodehash;
    }

    function finalize(
        bytes32 configHash,
        address factory,
        address exactSettler,
        address partialSettler,
        address governanceTimelock,
        address m2
    ) external onlyOwner {
        _checkConfig(configHash);
        if (finalized) {
            revert Bootstrap__AlreadyFinalized();
        }
        if (
            factory.code.length == 0 || exactSettler.code.length == 0
                || partialSettler.code.length == 0
        ) {
            revert Bootstrap__DependencyMissing(factory.code.length == 0
                    ? factory
                    : exactSettler.code.length == 0 ? exactSettler : partialSettler);
        }

        IAccessControl access = IAccessControl(factory);
        bytes32 defaultsRole = keccak256("DEFAULTS_MANAGER_ROLE");
        bytes32 approverRole = keccak256("SETTLER_APPROVER_ROLE");
        bytes32 revokerRole = keccak256("SETTLER_REVOKER_ROLE");
        bytes32 delayManagerRole = keccak256("TRUST_CONFIG_DELAY_MANAGER_ROLE");

        access.grantRole(bytes32(0), governanceTimelock);
        access.grantRole(defaultsRole, governanceTimelock);
        access.grantRole(approverRole, governanceTimelock);
        access.grantRole(revokerRole, m2);
        access.grantRole(delayManagerRole, governanceTimelock);

        ICorkRolloverContractFactoryAdmin(factory).approveSettler(exactSettler);
        ICorkRolloverContractFactoryAdmin(factory).approveSettler(partialSettler);

        access.renounceRole(defaultsRole, address(this));
        access.renounceRole(approverRole, address(this));
        access.renounceRole(revokerRole, address(this));
        access.renounceRole(delayManagerRole, address(this));
        access.renounceRole(bytes32(0), address(this));

        finalized = true;
        _transferOwnership(address(0));
    }

    function _checkConfig(bytes32 configHash) private view {
        if (
            !initialized || configHash != CONFIG_HASH || DEPLOYMENT_ARTIFACTS_HASH == bytes32(0)
                || finalized
        ) {
            revert Bootstrap__ConfigMismatch();
        }
    }
}

/// @notice Authenticated CREATE2 provenance anchor for the one-shot deployment bootstrap.
contract RolloverBootstrapDeployer {
    error BootstrapDeployer__Unauthorized(address caller);
    error BootstrapDeployer__AddressMismatch(address actual, address expected);
    error BootstrapDeployer__BootstrapMismatch(address bootstrap);

    bytes32 private constant BOOTSTRAP_SALT = keccak256("cork.rollover.bootstrap.v2");

    address public DEPLOYMENT_AUTHORITY;

    constructor(address deploymentAuthority) {
        if (deploymentAuthority == address(0)) {
            revert BootstrapDeployer__Unauthorized(address(0));
        }
        DEPLOYMENT_AUTHORITY = deploymentAuthority;
    }

    /// @notice Deploy and initialize the bootstrap in one authenticated transaction.
    function deployAndInitialize(
        bytes32 configHash,
        bytes32 deploymentArtifactsHash,
        address initialOwner
    ) external returns (RolloverDeploymentBootstrap bootstrap) {
        if (msg.sender != DEPLOYMENT_AUTHORITY) {
            revert BootstrapDeployer__Unauthorized(msg.sender);
        }
        address expected = _bootstrapAddress();
        if (expected.code.length == 0) {
            bootstrap = new RolloverDeploymentBootstrap{ salt: BOOTSTRAP_SALT }();
            if (address(bootstrap) != expected) {
                revert BootstrapDeployer__AddressMismatch(address(bootstrap), expected);
            }
            bootstrap.initialize(configHash, deploymentArtifactsHash, initialOwner);
            return bootstrap;
        }

        bootstrap = RolloverDeploymentBootstrap(expected);
        if (
            expected.codehash != keccak256(type(RolloverDeploymentBootstrap).runtimeCode)
                || !bootstrap.initialized() || bootstrap.CONFIG_HASH() != configHash
                || bootstrap.DEPLOYMENT_ARTIFACTS_HASH() != deploymentArtifactsHash
                || (bootstrap.finalized()
                        ? bootstrap.owner() != address(0)
                        : bootstrap.owner() != initialOwner)
        ) {
            revert BootstrapDeployer__BootstrapMismatch(expected);
        }
    }

    function bootstrapAddress() external view returns (address bootstrap) {
        bootstrap = _bootstrapAddress();
    }

    function _bootstrapAddress() private view returns (address bootstrap) {
        bootstrap = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            BOOTSTRAP_SALT,
                            keccak256(type(RolloverDeploymentBootstrap).creationCode)
                        )
                    )
                )
            )
        );
    }
}
