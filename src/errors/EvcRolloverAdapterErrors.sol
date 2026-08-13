// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @notice Reverts when the EVC reports the controller is not enabled for the subaccount.
error EvcRolloverAdapter__ControllerNotEnabled();

/// @notice Reverts when called outside an EVC `callOnBehalfOf` context.
error EvcRolloverAdapter__NotEvcContext();

/// @notice Reverts when the EVC's on-behalf-of subaccount does not match the job subaccount.
/// @param onBehalf Subaccount the EVC reports.
/// @param subaccount Job-declared subaccount.
error EvcRolloverAdapter__OnBehalfMismatch(address onBehalf, address subaccount);

/// @notice Reverts when the caller passes the zero address as the Settler.
error EvcRolloverAdapter__UnknownSettler();

/// @notice Reverts when the immutable Settler argument is zero at deployment.
error EvcRolloverAdapter__ZeroSettler();

/// @notice Reverts when the job's `settler` does not equal the immutable `SETTLER`.
/// @param expected Expected Settler (`SETTLER`).
/// @param actual Settler supplied in the job.
error EvcRolloverAdapter__SettlerMismatch(address expected, address actual);

/// @notice Reverts when the controller argument is zero at deployment.
error EvcRolloverAdapter__ZeroController();

/// @notice Reverts when the EVC argument is zero at deployment.
error EvcRolloverAdapter__ZeroEvc();

/// @notice Reverts when `_gateEvc` is called by an address other than the EVC.
error EvcRolloverAdapter__CallerNotEvc();

/// @notice Reverts when the Permit2 argument is zero at deployment.
error EvcRolloverAdapter__ZeroPermit2();

/// @notice Reverts when `job.fundingSig` is empty.
error EvcRolloverAdapter__FundingSigInvalid();

/// @notice Reverts when the resolved Permit2 signer for `job.subaccount`
///         is the zero address (subaccount has no registered EVC owner).
error EvcRolloverAdapter__SubaccountAuthorityMissing();

/// @notice Reverts when the job declares a zero Permit2 funding account.
error EvcRolloverAdapter__ZeroFundingAccount();

/// @notice Reverts when the job declares a zero settlement/refund recipient.
error EvcRolloverAdapter__ZeroRecipient();

/// @notice Reverts when the job funding account is not the EVC owner of the subaccount.
/// @param expected EVC-reported account owner.
/// @param actual Job-declared funding account.
error EvcRolloverAdapter__FundingAccountMismatch(address expected, address actual);

/// @notice Reverts when `executePartial` receives an exact-mode order.
error EvcRolloverAdapter__PartialOrderRequired();
