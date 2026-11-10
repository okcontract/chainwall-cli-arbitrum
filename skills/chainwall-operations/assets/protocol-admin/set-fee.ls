{
  $require($subjectPolicy == {{routinePolicyId}}),
  $require($subjectVault == {{adminAccount}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  @contract(myprotocol/params).setFee($arg0 :: uint256)
}
