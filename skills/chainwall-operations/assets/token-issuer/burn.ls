{
  $require($subjectPolicy == {{adminPolicyId}}),
  $require($subjectVault == {{issuerAccount}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 2),
  $require($arg1 > 0),
  @contract(myproject/token).burn($arg0 :: address, $arg1 :: uint256)
}
