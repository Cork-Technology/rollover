// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ExactSettler as Settler } from "src/ExactSettler.sol";

/// @notice Test harness exposing Settler internal functions for direct-call unit tests.
abstract contract SettlerHarness is Settler {
    /// @param factory_ Cork factory address.
    /// @param corkPoolManager_ Canonical Phoenix PoolManager singleton.
    /// @param admin_ Owner/admin/pauser/unpauser address.
    constructor(address factory_, address corkPoolManager_, address admin_)
        Settler(factory_, corkPoolManager_, admin_, admin_, admin_, admin_)
    { }
}
