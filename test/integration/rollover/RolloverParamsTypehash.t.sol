// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice RolloverParams typehash binds every signed destination and JIT creation field.
contract RolloverParamsTypehashTest is Test {
    /// @notice _base params.
    function _baseParams() internal pure returns (RolloverTypes.RolloverParams memory) {
        return RolloverTypes.RolloverParams({
            srcCstToken: address(0x1111),
            dstCstToken: address(0x2222),
            minCaReceived: 500e18,
            minSharesOut: 100e18,
            srcPoolId: bytes32(uint256(0xAA01)),
            dstPoolId: bytes32(uint256(0xAA02)),
            settler: address(0x3333),
            jitMarketHash: bytes32(uint256(0xAA03))
        });
    }

    /// @notice _hash.
    function _hash(RolloverTypes.RolloverParams memory p) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                Typehashes.ROLLOVER_PARAMS_TYPEHASH,
                p.srcCstToken,
                p.dstCstToken,
                p.minCaReceived,
                p.minSharesOut,
                p.srcPoolId,
                p.dstPoolId,
                p.settler,
                p.jitMarketHash
            )
        );
    }

    /// @notice Typehash preimage contains all eight fields.
    function test_typehashPreimageIsEightFields() public pure {
        bytes32 expected = keccak256(
            "RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes32 srcPoolId,bytes32 dstPoolId,address settler,bytes32 jitMarketHash)"
        );
        assertEq(Typehashes.ROLLOVER_PARAMS_TYPEHASH, expected);
    }

    /// @notice old six field preimage differs.
    function test_oldSixFieldPreimageDiffers() public pure {
        bytes32 oldHash = keccak256(
            "RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes preRolloverHooksData,bytes postRolloverHooksData)"
        );
        assertTrue(oldHash != Typehashes.ROLLOVER_PARAMS_TYPEHASH);
    }

    /// @notice two instances hash identically.
    function test_twoInstancesHashIdentically() public pure {
        RolloverTypes.RolloverParams memory a = _baseParams();
        RolloverTypes.RolloverParams memory b = _baseParams();
        assertEq(_hash(a), _hash(b));
    }

    /// @notice src pool id flips hash.
    function test_srcPoolIdFlipsHash() public pure {
        RolloverTypes.RolloverParams memory a = _baseParams();
        RolloverTypes.RolloverParams memory b = _baseParams();
        b.srcPoolId = bytes32(uint256(0xBB01));
        assertTrue(_hash(a) != _hash(b));
    }

    /// @notice dst pool id flips hash.
    function test_dstPoolIdFlipsHash() public pure {
        RolloverTypes.RolloverParams memory a = _baseParams();
        RolloverTypes.RolloverParams memory b = _baseParams();
        b.dstPoolId = bytes32(uint256(0xBB02));
        assertTrue(_hash(a) != _hash(b));
    }

    /// @notice settler flips hash.
    function test_settlerFlipsHash() public pure {
        RolloverTypes.RolloverParams memory a = _baseParams();
        RolloverTypes.RolloverParams memory b = _baseParams();
        b.settler = address(0x4444);
        assertTrue(_hash(a) != _hash(b));
    }

    /// @notice JIT market commitment flips hash.
    function test_jitMarketHashFlipsHash() public pure {
        RolloverTypes.RolloverParams memory a = _baseParams();
        RolloverTypes.RolloverParams memory b = _baseParams();
        b.jitMarketHash = bytes32(uint256(0xBB03));
        assertTrue(_hash(a) != _hash(b));
    }

    /// @notice Order data typehash embeds the complete eight-field substruct.
    function test_orderDataTypehashEmbedsEightFieldSubstruct() public pure {
        bytes32 expected = keccak256(
            "OrderData(address user,address settler,address fillerHint,address exclusiveFiller,address srcCstToken,address dstCstToken,address premiumToken,address rolloverContract,uint64 originChainId,uint64 destinationChainId,uint64 openDeadline,uint64 fillDeadline,uint64 orderSalt,uint256 orderSize,uint256 minPremiumPerShare,bool allowPartialFills,bool allowUnderfill,uint8 premiumPaymentMode,bytes32 rolloverIntentHash,RolloverParams rolloverParams)RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes32 srcPoolId,bytes32 dstPoolId,address settler,bytes32 jitMarketHash)"
        );
        assertEq(Typehashes.ORDER_DATA_TYPEHASH, expected);
    }
}
