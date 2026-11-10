{
  $require($subjectPolicy == {{routinePolicyId}}),
  $require($subjectVault == {{adminAccount}}),
  $require($subjectId == {{setFeeId}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  $require($subjectArg(0) <= 1000)
}
