{
  $require($subjectPolicy == {{adminPolicyId}}),
  $require($subjectVault == {{issuerAccount}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  @contract(myproject/token).setPaused($arg0 :: bool)
}
