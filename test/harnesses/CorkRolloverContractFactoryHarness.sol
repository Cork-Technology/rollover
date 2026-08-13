// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";

/// @notice Test harness exposing CorkRolloverContractFactory internal CWIA-argument decoding for direct unit testing.
contract CorkRolloverContractFactoryHarness is CorkRolloverContractFactory {
    /// @param rolloverContractImplementation_ CWIA rolloverContract implementation address.
    /// @param erc7484Registry_ ERC-7484 attester registry address.
    /// @param defaultThreshold_ Default trust threshold (number of attesters required).
    /// @param defaultAttesters_ Default attester addresses.
    /// @param trustConfigTimelock_ External trust-config timelock.
    /// @param ensOwner_ Phoenix-style owner identity.
    /// @param factoryAdmin_ DEFAULT_ADMIN_ROLE holder.
    /// @param defaultsManager_ DEFAULTS_MANAGER_ROLE holder.
    /// @param settlerApprover_ SETTLER_APPROVER_ROLE holder.
    /// @param settlerRevoker_ SETTLER_REVOKER_ROLE holder.
    constructor(
        address rolloverContractImplementation_,
        address erc7484Registry_,
        uint8 defaultThreshold_,
        address[] memory defaultAttesters_,
        address trustConfigTimelock_,
        address ensOwner_,
        address factoryAdmin_,
        address defaultsManager_,
        address settlerApprover_,
        address settlerRevoker_
    )
        CorkRolloverContractFactory(
            rolloverContractImplementation_,
            erc7484Registry_,
            defaultThreshold_,
            defaultAttesters_,
            trustConfigTimelock_,
            ensOwner_,
            factoryAdmin_,
            defaultsManager_,
            settlerApprover_,
            settlerRevoker_
        )
    { }

    /// @notice Exposes the internal CWIA argument decoder that recovers (owner, factory) from a clone's immutable trailing data.
    /// @param rolloverContract Cork rolloverContract address.
    /// @return ownerAddr Owner address.
    /// @return factoryAddr Cork factory address.
    function exposed_decodeCwiaArgs(address rolloverContract)
        external
        view
        returns (address ownerAddr, address factoryAddr)
    {
        return _decodeCwiaArgs(rolloverContract);
    }
}
