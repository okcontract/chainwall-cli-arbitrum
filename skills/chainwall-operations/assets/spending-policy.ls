{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectId == {{interactionId}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 2),
  $require($subjectArg(1) > 0 && $subjectArg(1) <= {{maxAmount}})
}
