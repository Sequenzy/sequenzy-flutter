Pod::Spec.new do |s|
  s.name             = 'sequenzy_flutter_geofences'
  s.version          = '0.2.0'
  s.summary          = 'Geofencing for the Sequenzy Flutter SDK.'
  s.description      = 'Core Location region monitoring that reports when the signed-in contact enters or leaves your Sequenzy geofences.'
  s.homepage         = 'https://sequenzy.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Sequenzy' => 'dev@sequenzy.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.resource_bundles = { 'sequenzy_flutter_geofences_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.frameworks       = 'CoreLocation'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
