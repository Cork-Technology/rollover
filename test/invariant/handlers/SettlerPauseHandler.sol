// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { ExactSettler } from "src/ExactSettler.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice INV-PAUSE-GATES-ALL-ENTRYPOINTS family handler — drives pause/unpause toggles and probes whenNotPaused gating.
/// @custom:invariant INV-PAUSE-GATES-ALL-ENTRYPOINTS
contract SettlerPauseHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Settler ref.
    /// @return settlerRef Stored settler ref value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    ExactSettler public immutable settlerRef;
    /// @notice Pauser.
    /// @return pauser Stored pauser value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable pauser;
    /// @notice Unpauser.
    /// @return unpauser Stored unpauser value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable unpauser;
    /// @notice Accepted any call while paused.
    /// @return acceptedAnyCallWhilePaused Stored accepted any call while paused value.

    bool public acceptedAnyCallWhilePaused;
    /// @notice View blocked while paused.
    /// @return viewBlockedWhilePaused Stored view blocked while paused value.

    bool public viewBlockedWhilePaused;
    /// @notice Accepted calls total.
    /// @return acceptedCallsTotal Stored accepted calls total value.

    uint64 public acceptedCallsTotal;
    /// @notice Accepted calls while paused.
    /// @return acceptedCallsWhilePaused Stored accepted calls while paused value.

    uint64 public acceptedCallsWhilePaused;
    /// @notice Pause toggles.
    /// @return pauseToggles Stored pause toggles value.

    uint64 public pauseToggles;

    // forge-lint: disable-next-line(missing-zero-check)
    /// @param unpauser_ unpauser_.
    /// @param pauser_ pauser_.
    /// @param settler_ settler_.
    // Invariant handler mirrors arbitrary pause-role actors configured by the fixture.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(ExactSettler settler_, address pauser_, address unpauser_) {
        settlerRef = settler_;
        pauser = pauser_;
        unpauser = unpauser_;
    }

    /// @notice handler action: do pause.
    function doPause() external {
        if (settlerRef.paused()) {
            return;
        }
        vm.prank(pauser);
        try settlerRef.pause() {
            pauseToggles++;
        } catch { }
    }

    /// @notice handler action: do unpause.
    function doUnpause() external {
        if (!settlerRef.paused()) {
            return;
        }
        vm.prank(unpauser);
        try settlerRef.unpause() {
            pauseToggles++;
        } catch { }
    }

    /// @notice handler action: probe open.
    /// @param seed Fuzz seed.
    function probeOpen(uint256 seed) external {
        address caller = _caller(seed);
        bool wasPaused = settlerRef.paused();
        vm.prank(caller);
        try settlerRef.openFor(_emptyGasless(), bytes(""), "") {
            _recordAccepted(wasPaused);
        } catch { }
    }

    /// @notice handler action: probe open for.
    /// @param seed Fuzz seed.
    function probeOpenFor(uint256 seed) external {
        address caller = _caller(seed);
        bool wasPaused = settlerRef.paused();
        vm.prank(caller);
        try settlerRef.openFor(_emptyGasless(), bytes(""), bytes("")) {
            _recordAccepted(wasPaused);
        } catch { }
    }

    /// @notice handler action: probe fill.
    /// @param seed Fuzz seed.
    function probeFill(uint256 seed) external {
        address caller = _caller(seed);
        bool wasPaused = settlerRef.paused();
        vm.prank(caller);
        try settlerRef.fill(bytes32(0), bytes(""), bytes("")) {
            _recordAccepted(wasPaused);
        } catch { }
    }

    /// @notice handler action: probe reclaim.
    /// @param seed Fuzz seed.
    function probeReclaim(uint256 seed) external {
        address caller = _caller(seed);
        bool wasPaused = settlerRef.paused();
        vm.prank(caller);
        try settlerRef.reclaim(bytes32(0), address(0), bytes32(0), bytes("")) {
            _recordAccepted(wasPaused);
        } catch { }
    }

    /// @notice handler action: probe markExpired.
    /// @param seed Fuzz seed.
    function probeMarkExpired(uint256 seed) external {
        address caller = _caller(seed);
        bool wasPaused = settlerRef.paused();
        vm.prank(caller);
        try settlerRef.markExpired(bytes32(0), bytes("")) {
            _recordAccepted(wasPaused);
        } catch { }
    }

    /// @notice handler action: probe cancel.
    /// @param seed Fuzz seed.
    function probeCancel(uint256 seed) external {
        address caller = _caller(seed);
        bool wasPaused = settlerRef.paused();
        vm.prank(caller);
        try settlerRef.cancel(bytes32(0), bytes(""), bytes("")) {
            _recordAccepted(wasPaused);
        } catch { }
    }

    /// @notice handler action: probe views.
    /// @param seed Fuzz seed.
    function probeViews(bytes32 seed) external {
        bool wasPaused = settlerRef.paused();
        try settlerRef.orderStatus(seed) returns (RolloverTypes.OrderStatus) { }
        catch {
            if (wasPaused) {
                viewBlockedWhilePaused = true;
            }
        }
    }

    /// @notice _record accepted.
    function _recordAccepted(bool wasPaused) private {
        acceptedCallsTotal++;
        if (wasPaused) {
            acceptedAnyCallWhilePaused = true;
            acceptedCallsWhilePaused++;
        }
    }

    /// @notice _caller.
    function _caller(uint256 seed) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("pause-caller", seed)))) | 1);
    }

    /// @notice _empty gasless.
    function _emptyGasless() private pure returns (ERC7683Types.GaslessCrossChainOrder memory g) {
        g = ERC7683Types.GaslessCrossChainOrder({
            originSettler: address(0),
            user: address(0),
            nonce: 0,
            originChainId: 0,
            openDeadline: 0,
            fillDeadline: 0,
            orderDataType: bytes32(0),
            orderData: bytes("")
        });
    }
}
