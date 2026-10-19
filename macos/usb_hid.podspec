#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint usb_hid.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'usb_hid'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files = 'usb_hid/Sources/usb_hid/**/*.swift'
  s.resource_bundles = {'usb_hid_privacy' => ['usb_hid/Sources/usb_hid/Resources/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'
  s.framework = 'IOKit'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
