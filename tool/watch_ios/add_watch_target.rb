# Adds the Apple Watch app "Felt Notes Pulse" (target FeltNotesWatch) to
# ios/Runner.xcodeproj and wires the Pulse bridge into Runner. Idempotent: run
# it again after editing this file and it converges (settings are rewritten,
# nothing is duplicated). See docs/PULSE.md.
#
#   tool/watch_ios/add_watch_target.sh        (finds CocoaPods' ruby + xcodeproj gem)
#
# Why each piece:
# * Target dir ios/FeltNotesWatch must match the target name, and its Info.plist
#   must hold the literal WKCompanionAppBundleIdentifier: that is how
#   `flutter build ios` notices a watch companion and stops passing
#   `-sdk iphoneos` (which would build the watch app with the iOS SDK).
# * Embed phase sits before Flutter's "Thin Binary" / CocoaPods script phases
#   (avoids Xcode's "Cycle inside Runner" with embedded products).
# * Watch target is not in the Podfile, so `pod install` leaves it alone.
require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
PROJECT_PATH = File.join(ROOT, 'ios', 'Runner.xcodeproj')

WATCH_TARGET = 'FeltNotesWatch'
WATCH_BUNDLE_ID = 'com.sagearbor.feltnotes.app.watchkitapp'
TEAM = '553Y9KWR84'
EMBED_PHASE = 'Embed Watch Content'
WATCH_SOURCES = %w[FeltNotesWatchApp.swift ContentView.swift PulseSession.swift].freeze
WATCH_OTHER = %w[Info.plist FeltNotesWatch.entitlements Watch.xcconfig].freeze
SHARED_DIR = 'PulseShared'
SHARED_SOURCES = %w[PulseProtocol.swift].freeze
RUNNER_SOURCES = %w[PulseChannel.swift].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)
main = project.main_group

def group_for(parent, name)
  parent.groups.find { |g| g.path == name || g.name == name } ||
    parent.new_group(name, name)
end

def file_ref(group, name)
  group.files.find { |f| f.path == name } || group.new_reference(name)
end

def ensure_source(target, ref)
  phase = target.source_build_phase
  phase.add_file_reference(ref) unless phase.files_references.include?(ref)
end

def ensure_resource(target, ref)
  phase = target.resources_build_phase
  phase.add_file_reference(ref) unless phase.files_references.include?(ref)
end

runner = project.targets.find { |t| t.name == 'Runner' } or abort('Runner target not found')

# --- Shared protocol + Runner bridge -----------------------------------------
shared_group = group_for(main, SHARED_DIR)
shared_refs = SHARED_SOURCES.map { |f| file_ref(shared_group, f) }
runner_group = main.groups.find { |g| g.path == 'Runner' || g.name == 'Runner' } or abort('Runner group not found')
RUNNER_SOURCES.each { |f| ensure_source(runner, file_ref(runner_group, f)) }
shared_refs.each { |r| ensure_source(runner, r) }

# --- Watch target -------------------------------------------------------------
watch = project.targets.find { |t| t.name == WATCH_TARGET }
unless watch
  watch = project.new_target(:application, WATCH_TARGET, :watchos, '10.0', nil, :swift)
  puts "created target #{WATCH_TARGET}"
end

# new_target links Foundation by a hardcoded SDK path (WatchOS26.0.sdk) that
# breaks on other Xcodes. Swift auto-links system frameworks; drop it.
watch.frameworks_build_phase.files.dup.each do |bf|
  ref = bf.file_ref
  next unless ref && ref.path.to_s.include?('WatchOS') && ref.path.to_s.end_with?('.framework')
  watch.frameworks_build_phase.remove_build_file(bf)
  ref.remove_from_project if ref.build_files.empty?
end
project.frameworks_group.groups.select { |g| g.name == 'watchOS' && g.children.empty? }.each(&:remove_from_project)

watch_group = group_for(main, WATCH_TARGET)
WATCH_SOURCES.each { |f| ensure_source(watch, file_ref(watch_group, f)) }
shared_refs.each { |r| ensure_source(watch, r) }
ensure_resource(watch, file_ref(watch_group, 'Assets.xcassets'))
WATCH_OTHER.each { |f| file_ref(watch_group, f) }
xcconfig = watch_group.files.find { |f| f.path == 'Watch.xcconfig' }

common = {
  'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
  'CLANG_ENABLE_MODULES' => 'YES',
  'CODE_SIGN_ENTITLEMENTS' => "#{WATCH_TARGET}/FeltNotesWatch.entitlements",
  'CODE_SIGN_STYLE' => 'Automatic',
  # Versions come from Flutter's Generated.xcconfig (via Watch.xcconfig) so
  # they always equal the iPhone app's.
  'CURRENT_PROJECT_VERSION' => '$(FLUTTER_BUILD_NUMBER)',
  'MARKETING_VERSION' => '$(FLUTTER_BUILD_NAME)',
  'DEVELOPMENT_TEAM' => TEAM,
  'GENERATE_INFOPLIST_FILE' => 'NO',
  'INFOPLIST_FILE' => "#{WATCH_TARGET}/Info.plist",
  'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
  'PRODUCT_BUNDLE_IDENTIFIER' => WATCH_BUNDLE_ID,
  'PRODUCT_NAME' => '$(TARGET_NAME)',
  'SDKROOT' => 'watchos',
  'SKIP_INSTALL' => 'YES',
  'SUPPORTED_PLATFORMS' => 'watchos watchsimulator',
  'SWIFT_EMIT_LOC_STRINGS' => 'NO',
  'SWIFT_VERSION' => '5.0',
  'TARGETED_DEVICE_FAMILY' => '4',
  'WATCHOS_DEPLOYMENT_TARGET' => '10.0',
}.freeze
debug_only = {
  'DEBUG_INFORMATION_FORMAT' => 'dwarf',
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'DEBUG',
  'SWIFT_OPTIMIZATION_LEVEL' => '-Onone',
}.freeze
release_only = {
  'DEBUG_INFORMATION_FORMAT' => 'dwarf-with-dsym',
  'SWIFT_COMPILATION_MODE' => 'wholemodule',
  'SWIFT_OPTIMIZATION_LEVEL' => '-O',
}.freeze

# One config per project config (Debug / Release / Profile), settings rewritten.
project.build_configurations.map(&:name).each do |name|
  config = watch.build_configurations.find { |c| c.name == name } ||
           watch.add_build_configuration(name, name == 'Debug' ? :debug : :release)
  config.build_settings = common.merge(name == 'Debug' ? debug_only : release_only)
  config.base_configuration_reference = xcconfig
end
watch.build_configuration_list.default_configuration_name = 'Release'

# --- Runner embeds and depends on the watch app -------------------------------
runner.add_dependency(watch) unless runner.dependencies.any? { |d| d.target == watch }

embed = runner.copy_files_build_phases.find { |p| p.name == EMBED_PHASE }
unless embed
  embed = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
  embed.name = EMBED_PHASE
  resources_index = runner.build_phases.index(runner.resources_build_phase)
  runner.build_phases.insert(resources_index + 1, embed)
end
embed.dst_subfolder_spec = '16' # products directory
embed.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
embed.run_only_for_deployment_postprocessing = '0'
unless embed.files_references.include?(watch.product_reference)
  bf = embed.add_file_reference(watch.product_reference)
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

attrs = project.root_object.attributes['TargetAttributes'] ||= {}
attrs[watch.uuid] = (attrs[watch.uuid] || {}).merge('CreatedOnToolsVersion' => '26.3')

project.save
puts "ok: #{WATCH_TARGET} (#{WATCH_BUNDLE_ID}) embedded in Runner/Watch"
