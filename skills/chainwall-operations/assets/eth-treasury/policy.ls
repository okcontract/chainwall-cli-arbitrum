{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectArgCount == 1),
  $require($subjectArg(0) > 0 && $subjectArg(0) <= {{capWei}}),
  $require(($subjectId == {{wrapId}} && $subjectNativeValue == $subjectArg(0)) || (($subjectId == {{unwrapId}} || $subjectId == {{payId}}) && $subjectNativeValue == 0))
}
