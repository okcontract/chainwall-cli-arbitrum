{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectArgCount == 1),
  $require($arg0 > 0),
  $require($subjectNativeValue == $arg0),
  @token(weth/weth).deposit{value: $arg0}()
}
