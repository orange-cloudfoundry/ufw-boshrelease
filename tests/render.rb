# Render job templates for the e2e container test (mirrors bosh template rendering).
require 'erb'
require 'json'
require 'yaml'
require 'fileutils'

class FakeSpec
  def initialize(name) = @name = name
  attr_reader :name
end

class Tpl
  def initialize(props, spec_name, defaults = {})
    @props = props
    @spec = FakeSpec.new(spec_name)
    @defaults = defaults
  end
  attr_reader :spec

  def p(key, default = :none)
    return @props[key] if @props.key?(key)
    return @defaults[key] if @defaults.key?(key)
    raise "property '#{key}' not set and no default" if default == :none
    default
  end

  def render(path)
    ERB.new(File.read(path), trim_mode: '-').result(binding)
  end
end

# mirror bosh: unset properties resolve through the job spec defaults
def spec_defaults(tpl_dir)
  path = File.join(File.dirname(tpl_dir), 'spec')
  YAML.safe_load(File.read(path)).fetch('properties', {}).transform_values do |v|
    v.is_a?(Hash) ? v['default'] : nil
  end.reject { |_, v| v.nil? }
end

tpl_dir, props_file, out_dir = ARGV
props = JSON.parse(File.read(props_file))
spec_name = props.delete('__spec_name')
tpl = Tpl.new(props, spec_name, spec_defaults(tpl_dir))

MAPPING = {
  'ufw.json.erb' => 'config/ufw.json',
  'ufw-cli.erb' => 'bin/ufw',
  'pre-start.erb' => 'bin/pre-start',
  'start.erb' => 'bin/start',
  'stop.erb' => 'bin/stop',
  'monit_check.erb' => 'bin/monit_check',
  'ctl.erb' => 'bin/ctl',
  'daemon.sh.erb' => 'bin/daemon',
}

FileUtils.mkdir_p(File.join(out_dir, 'bin')); FileUtils.mkdir_p(File.join(out_dir, 'config'))
MAPPING.each do |src, dst|
  out = tpl.render(File.join(tpl_dir, src))
  path = File.join(out_dir, dst)
  File.write(path, out)
  FileUtils.chmod(0o755, path) if dst.start_with?('bin/')
end
puts "rendered #{MAPPING.size} files to #{out_dir}"
