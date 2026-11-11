{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  $require($arg0 > 0),
  $require(@token(circle/usdc).transfer({{recipient}} :: address, $arg0 :: uint256))
}
