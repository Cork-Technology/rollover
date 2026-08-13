// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @notice User (cPT holder) signature over the order digest is invalid. Surfaced by
///         both `openFor` admission and direct-fill `None`-branch admission — both
///         gates verify the same EIP-712 cPT-holder signature on `orderDigest` (see
///         INV-DIRECT-FILL-CPT-HOLDER-SIG).
error Settler__BadUserSignature();

/// @notice Fill was attempted after the signed fill deadline.
error Settler__FillAfterDeadline();

/// @notice Order envelope open deadline does not match order data.
error Settler__OpenDeadlineMismatch();

/// @notice Order envelope fill deadline does not match order data.
error Settler__FillDeadlineMismatch();

/// @notice Open was attempted after the signed open deadline.
error Settler__OpenAfterOpenDeadline();

/// @notice Open deadline is later than fill deadline.
error Settler__OpenDeadlineAfterFillDeadline();

/// @notice Operation is blocked by the current terminal order status.
error Settler__OrderInTerminalState();

/// @notice Order status cannot be marked expired.
error Settler__OrderNotExpirable();

/// @notice Order status cannot be cancelled.
error Settler__OrderNotCancellable();

/// @notice Supplied order id does not match decoded order data.
error Settler__OrderIdMismatch();

/// @notice Cancel signature is not authorized by the order user.
error Settler__UnauthorizedCancel();

/// @notice Order references a rolloverContract that the factory has not deployed.
/// @param user User whose rolloverContract was expected.
error Settler__RolloverContractNotDeployed(address user);

/// @notice Order user is not the owner of the referenced rolloverContract.
/// @param user Signed order user.
/// @param rolloverContract Referenced rolloverContract.
error Settler__UserNotRolloverContractOwner(address user, address rolloverContract);

/// @notice Destination CST token equals premium token.
error Settler__DstCstEqualsPremiumToken();

/// @notice `markExpired` was attempted before the order's fill deadline passed.
error Settler__MarkExpiredBeforeFillDeadline();

/// @notice Source CST token equals premium token.
error Settler__SrcCstEqualsPremiumToken();

/// @notice Source and destination pool ids are identical.
error Settler__SamePoolId();

/// @notice Caller is not authorized by the exclusive filler.
/// @param exclusiveFiller Filler that must authorize the call.
/// @param caller Unauthorized caller.
error Settler__UnauthorizedFiller(address exclusiveFiller, address caller);

/// @notice Order origin chain does not match this chain.
error Settler__WrongOriginChain();

/// @notice Minimum premium rate is zero.
error Settler__ZeroPremiumRate();

/// @notice Exact settle requires the premium leg to be paid first.
error Settler__PremiumNotSettled();

/// @notice Cancel is blocked because the order already has fills.
error Settler__OrderHasFills();

/// @notice Premium token delivery to the settler did not match the fillerPayload.
/// @param expected Expected premium token amount.
/// @param actual Actual premium token amount received.
error Settler__PremiumDeliveryMismatch(uint256 expected, uint256 actual);

/// @notice Destination mint output is below the filler supplied floor.
/// @param required Required destination CST amount.
/// @param actual Actual destination CST amount.
error Settler__InsufficientMintRate(uint256 required, uint256 actual);

/// @notice Partial settle requires premium to be paid first.
error Settler__PremiumNotPaid();

/// @notice Partial filler residual has already been settled or reclaimed.
error Settler__FillerAlreadySettled();

/// @notice No destination CST residual is available to reclaim.
error Settler__NoResidualToReclaim();

/// @notice Reclaim is not available for the order's current lifecycle status.
error Settler__OrderNotReclaimable();

/// @notice Reclaim was attempted before the order's fill deadline passed.
error Settler__ReclaimBeforeFillDeadline();

/// @notice Exact-mode settle identity assertion failed: the caller-supplied `filler`
///         argument did not match the recorded `exactRec.filler`. The argument is
///         identity-asserting, not a recipient-resolution key; permissionless callers
///         cannot redirect or strand residuals by passing a stranger or zero address.
/// @param recorded Recorded filler from the rollover record.
/// @param supplied Caller-supplied filler argument.
error Settler__ExactFillerMismatch(address recorded, address supplied);

/// @notice Partial filler cannot add more rollover after its premium fired.
error Settler__PremiumAlreadyFiredRollover();

/// @notice ROLLOVER factory dispatch produced zero destination CST.
error Settler__ZeroMint();

/// @notice RolloverContract did not deliver the reported destination CST amount.
/// @param reported Reported destination CST produced.
/// @param delivered Destination CST actually delivered.
error Settler__DstProducedNotDelivered(uint256 reported, uint256 delivered);

/// @notice RolloverContract refunded less source CST than the reported leftover. Relaxed parity with
///         the dst-side `Settler__DstProducedNotDelivered` floor: third-party donations or
///         hostile-hook reinjections may PUSH `srcDelta` ABOVE `srcLeftover` without bricking
///         the order; only a genuine shortfall (`srcDelta < srcLeftover`) reverts.
/// @param reported Reported source CST leftover (rolloverContract's view).
/// @param delivered Source CST actually delivered to the Settler post-leg.
error Settler__SrcLeftoverDeliveryShortfall(uint256 reported, uint256 delivered);

/// @notice Order envelope origin settler does not match order data.
error Settler__OriginSettlerMismatch();

/// @notice Order envelope user does not match order data.
error Settler__UserMismatch();

/// @notice Order envelope nonce does not match order salt.
error Settler__OrderSaltMismatch();

/// @notice Order envelope origin chain id does not match order data.
error Settler__OriginChainIdMismatch();

/// @notice Order data settler does not match this contract.
error Settler__SettlerMismatch();

/// @notice Exclusive filler cannot be the settler itself.
error Settler__SelfExclusiveFiller();

/// @notice Order size cannot be zero.
error Settler__ZeroOrderSize();

/// @notice Fill deadline is not before both Phoenix pool expiries.
/// @param deadline Signed fill deadline.
/// @param srcExpiry Source pool expiry.
/// @param dstExpiry Destination pool expiry.
error Settler__FillDeadlineExceedsPoolExpiry(uint64 deadline, uint256 srcExpiry, uint256 dstExpiry);

/// @notice Source CST token cannot be zero.
error Settler__ZeroSrcCstToken();

/// @notice Destination CST token cannot be zero.
error Settler__ZeroDstCstToken();

/// @notice Premium token cannot be zero.
error Settler__ZeroPremiumToken();

/// @notice Rollover intent hash cannot be zero.
error Settler__ZeroRolloverIntentHash();

/// @notice Rollover params source CST token does not match order data.
error Settler__RolloverParamsSrcCstMismatch();

/// @notice Rollover params destination CST token does not match order data.
error Settler__RolloverParamsDstCstMismatch();

/// @notice Rollover params settler does not equal the top-level order data settler.
error Settler__RolloverParamsSettlerMismatch();

/// @notice Order destination chain does not match this chain.
error Settler__WrongDestinationChain();

/// @notice A required constructor address argument is zero.
error Settler__ZeroAddress();

/// @notice Source CST token is not canonical for the source pool id.
error Settler__SrcCstNotCanonical();

/// @notice Destination CST token is not canonical for the destination pool id.
error Settler__DstCstNotCanonical();

/// @notice Exact settler rejected a partial-fill order.
error Settler__PartialFillsNotSupported();

/// @notice Partial settler rejected an exact-fill order.
error Settler__ExactFillsNotSupported();

/// @notice Rollover source amount is outside the valid order range.
/// @param orderSize Signed order size.
/// @param amount Requested leg amount or aggregate consumed source amount.
error Settler__RolloverAmountOutOfBounds(uint256 orderSize, uint256 amount);

/// @notice Exact-strict (`!allowUnderfill`) fill must equal the full signed order size.
/// @param orderSize Signed order size.
/// @param fillAmount Filler-supplied fill amount.
error Settler__ExactFillRequiresFullOrderSize(uint256 orderSize, uint256 fillAmount);

/// @notice Exact-strict (`!allowUnderfill`) leg: rolloverContract reported nonzero srcLeftover.
/// @param srcLeftover Reported source CST leftover.
error Settler__ExactNoUnderfillRolloverContractReturnedLeftover(uint256 srcLeftover);

/// @notice `fill` invoked without an atomic envelope or supported dispatch tag.
error Settler__AtomicFillRequired();

/// @notice Async rollover, premium, or reclaim requires cPT holder opt-in.
error Settler__AsyncPremiumOptInRequired();

/// @notice Atomic-fill required premium exceeds the filler-supplied cap.
/// @param cap Filler-supplied premium cap from the atomic envelope.
/// @param required Ceil-rounded `produced * minPremiumPerShare / 1e18`.
error Settler__PremiumExceedsCap(uint256 cap, uint256 required);

/// @notice cPT-holder-signed premium payment mode is outside the supported atomic-only range.
error Settler__InvalidPremiumPaymentMode();

/// @notice Filler payload phase does not match the required entrypoint phase.
error Settler__UnknownPhase();

/// @notice Order already has a rollover record for the requested slot.
error Settler__AlreadyFilled();

/// @notice Premium was attempted before a rollover slot existed.
error Settler__PremiumBeforeRollover();

/// @notice No rollover slot exists for the supplied filler/sub-filler key.
error Settler__NoRolloverLegForFiller();

/// @notice Premium payload must identify the rollover filler being paid.
error Settler__PremiumForRequired();

/// @notice Premium payload does not match the recorded exact-mode filler.
error Settler__PremiumForMismatch();

/// @notice Exact-mode premium supplied a sub-filler that differs from the recorded rollover slot.
/// @param recorded Recorded rollover sub-filler.
/// @param supplied Supplied premium sub-filler.
error Settler__ExactSubFillerMismatch(bytes32 recorded, bytes32 supplied);

/// @notice Premium payload supplied a destination that differs from the recorded rollover destination.
error Settler__PremiumDestinationMismatch();

/// @notice ROLLOVER and PREMIUM payload shapes were mixed.
error Settler__PremiumForOnlyPremiumPhase();

/// @notice Premium has already fired for this rollover slot.
error Settler__PremiumAlreadyFired();

/// @notice Amount cannot be zero.
error Settler__ZeroAmount();

/// @notice RolloverContract reported more source CST leftover than the filler supplied.
/// @param reported Reported source CST leftover.
/// @param fillAmount Filler-supplied source CST amount.
error Settler__SrcLeftoverExceedsFillAmount(uint256 reported, uint256 fillAmount);

/// @notice Settler token balance is below tracked dstCST liability.
error Settler__UnderfundedDstCstLiability();

/// @notice ERC-20 rescue amount exceeds balance not backing dstCST liability.
error Settler__InsufficientRecoverableBalance();
