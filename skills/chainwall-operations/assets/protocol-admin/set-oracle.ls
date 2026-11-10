{
  $require($subjectPolicy == {{sensitivePolicyId}}),
  $require($subjectVault == {{adminAccount}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  @contract(myprotocol/params).setOracle($arg0 :: address)
}
