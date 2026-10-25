{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 2),
  $require($arg0 != 0),
  $require($arg1 > 0),
  $require(@token({{tokenPath}}).transfer($arg0 :: address, $arg1 :: uint256))
}
