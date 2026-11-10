{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 2),
  $require($subjectArg(0) > 0),
  $require($subjectArg(1) > 0),
  $require(($subjectId == {{w2uId}} && $subjectArg(0) <= {{capWethIn}}) || ($subjectId == {{u2wId}} && $subjectArg(0) <= {{capUsdcIn}}))
}
