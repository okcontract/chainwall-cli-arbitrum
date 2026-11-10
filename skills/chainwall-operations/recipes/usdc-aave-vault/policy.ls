{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectId == {{supplyId}} || $subjectId == {{withdrawId}} || $subjectId == {{payoutId}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  $require($subjectArg(0) > 0 && $subjectArg(0) <= 100000000)
}
