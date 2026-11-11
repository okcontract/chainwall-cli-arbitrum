{
  $require($subjectPolicy == {{adminPolicyId}}),
  $require($subjectVault == {{issuerAccount}}),
  $require($subjectId == {{burnId}} || $subjectId == {{pauseId}}),
  $require($subjectNativeValue == 0)
}
