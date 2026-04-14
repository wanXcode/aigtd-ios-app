source 'https://cdn.cocoapods.org/'
source 'https://github.com/volcengine/volcengine-specs.git'

install! 'cocoapods', warn_for_unused_master_specs_repo: false

platform :ios, '18.0'
inhibit_all_warnings!

target 'AIGTDReminders' do
  use_frameworks!

  pod 'SpeechEngineAsrToB', '1.1.7'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '12.0'
      config.build_settings['CLANG_WARN_NULLABILITY_COMPLETENESS'] = 'NO'
      config.build_settings['CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER'] = 'NO'
      config.build_settings['ENABLE_MODULE_VERIFIER'] = 'NO'
      config.build_settings['GCC_TREAT_WARNINGS_AS_ERRORS'] = 'NO'
      config.build_settings['WARNING_CFLAGS'] = '$(inherited) -Wno-nullability-completeness -Wno-nullability-completeness-on-arrays'
    end
  end
end

post_integrate do |installer|
  pods_project_path = File.join(installer.sandbox.root.to_s, 'Pods.xcodeproj', 'project.pbxproj')
  next unless File.exist?(pods_project_path)

  content = File.read(pods_project_path)
  rewritten = content.gsub('ENABLE_MODULE_VERIFIER = YES;', 'ENABLE_MODULE_VERIFIER = NO;')
  File.write(pods_project_path, rewritten) if rewritten != content
end
