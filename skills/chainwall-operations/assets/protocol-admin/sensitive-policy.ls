{
  $require($subjectPolicy == {{sensitivePolicyId}}),
  $require($subjectVault == {{adminAccount}}),
  $require($subjectId == {{setOracleId}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  $require($subjectArg(0) != 0)
}
