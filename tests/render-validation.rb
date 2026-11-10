#!/usr/bin/env ruby
# Standalone render/validation harness for the ufw job ERB templates
# (BOSH renders these with ruby; this mimics the minimal context: p() and spec.name)
require 'erb'
require 'json'
require 'yaml'

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
    src = ERB.new(File.read(path), trim_mode: '-').result(binding)
    src
  end

  def self.compile_check(path)
    RubyVM::InstructionSequence.compile(ERB.new(File.read(path), trim_mode: '-').src)
    :ok
  end
end

VALID_PROPS = {
  'ufw.logging' => 'low',
  'ufw.ipv6' => true,
  'ufw.enforce' => false,
  'ufw.stay_armed_on_stop' => true,
  'ufw.allow_bosh' => [
    { 'description' => 'bosh agent', 'from' => ['10.0.4.0/24'], 'to_ports' => [25555, 4222], 'protocol' => 'tcp' },
    { 'description' => 'ssh from jumpbox', 'from' => ['10.0.4.50/32'], 'to_ports' => [22], 'protocol' => 'tcp' },
  ],
  'ufw.rules' => [
    { 'description' => 'mysql from apps subnet', 'from' => ['10.20.30.0/24'], 'to_ports' => [3306], 'protocol' => 'tcp' },
    { 'description' => 'range+multi', 'from' => ['10.20.30.0/24', 'fe80::/64'], 'to_ports' => ['3306:3308', 6379], 'protocol' => 'tcp/udp' },
  ],
}

failures = 0
check = lambda do |name, expectation|
  begin
    result = expectation.call
    if result == :ok
      puts "PASS #{name}"
    else
      puts "FAIL #{name}: got #{result.inspect}"
      failures += 1
    end
  rescue => e
    puts "FAIL #{name}: unexpected #{e.class}: #{e.message}"
    failures += 1
  end
end

tpl_dir = ARGV[0]

SPEC_DEFAULTS = File.open(File.join(File.dirname(tpl_dir), 'spec')) do |f|
  YAML.safe_load(f.read).fetch('properties', {}).transform_values { |v| v.is_a?(Hash) ? v['default'] : nil }.reject { |_, v| v.nil? }
end

# 1. all templates compile as ERB/ruby
Dir.glob(File.join(tpl_dir, '*.erb')).each do |t|
  check.call("compile #{File.basename(t)}", -> { Tpl.compile_check(t) })
end

# 2. happy path rendering + exact command strings
check.call('render ufw.json valid props', lambda do
  out = Tpl.new(VALID_PROPS, 'mysql').render(File.join(tpl_dir, 'ufw.json.erb'))
  json = JSON.parse(out)
  expect = [
    "allow from 10.0.4.0/24 to any port 25555 proto tcp comment 'paas-ufw/mysql bosh agent'",
    "allow from 10.0.4.0/24 to any port 4222 proto tcp comment 'paas-ufw/mysql bosh agent'",
    "allow from 10.0.4.50/32 to any port 22 proto tcp comment 'paas-ufw/mysql ssh from jumpbox'",
    "allow from 10.20.30.0/24 to any port 3306 proto tcp comment 'paas-ufw/mysql mysql from apps subnet'",
    "allow from 10.20.30.0/24 to any port 3306:3308 proto tcp/udp comment 'paas-ufw/mysql range+multi'",
    "allow from 10.20.30.0/24 to any port 6379 proto tcp/udp comment 'paas-ufw/mysql range+multi'",
    "allow from fe80::/64 to any port 3306:3308 proto tcp/udp comment 'paas-ufw/mysql range+multi'",
    "allow from fe80::/64 to any port 6379 proto tcp/udp comment 'paas-ufw/mysql range+multi'",
  ]
  raise "commands mismatch:\n got: #{json['commands'].inspect}\nwant: #{expect.inspect}" unless json['commands'] == expect
  raise 'tag wrong' unless json['tag'] == 'paas-ufw/mysql'
  raise 'enforce wrong' unless json['enforce'] == false
  raise 'ipv6 wrong' unless json['ipv6'] == true
  :ok
end)

# 2b. unset ipv6 resolves through the job spec default (false: BOSH is IPv4-only)
check.call('unset ipv6 renders false', lambda do
  props = VALID_PROPS.reject { |k, _| k == 'ufw.ipv6' }
  json = JSON.parse(Tpl.new(props, 'g', SPEC_DEFAULTS).render(File.join(tpl_dir, 'ufw.json.erb')))
  raise "ipv6=#{json['ipv6'].inspect}" unless json['ipv6'] == false
  :ok
end)

# 3. scalar from/to_ports normalized
check.call('render scalar from/to_ports', lambda do
  props = VALID_PROPS.merge(
    'ufw.allow_bosh' => [{ 'description' => 'd', 'from' => '10.0.0.0/8', 'to_ports' => 22, 'protocol' => 'tcp' }],
    'ufw.rules' => []
  )
  json = JSON.parse(Tpl.new(props, 'g').render(File.join(tpl_dir, 'ufw.json.erb')))
  raise "got #{json['commands'].inspect}" unless json['commands'] == ["allow from 10.0.0.0/8 to any port 22 proto tcp comment 'paas-ufw/g d'"]
  :ok
end)

# 4. expected failures
must_raise = lambda do |name, mutate|
  check.call(name, lambda do
    props = mutate.call
    begin
      Tpl.new(props, 'g').render(File.join(tpl_dir, 'ufw.json.erb'))
      "no raise for #{name}"
    rescue RuntimeError => e
      puts "  (expected: #{e.message[0, 90]})"
      :ok
    end
  end)
end

must_raise.call('empty allow_bosh rejected', -> { VALID_PROPS.merge('ufw.allow_bosh' => []) })
must_raise.call('invalid CIDR rejected', -> { VALID_PROPS.merge('ufw.rules' => [{ 'description' => 'x', 'from' => ['10.20.30.256/24'], 'to_ports' => [1], 'protocol' => 'tcp' }]) })
must_raise.call('CIDR without prefix rejected', -> { VALID_PROPS.merge('ufw.rules' => [{ 'description' => 'x', 'from' => ['10.20.30.0'], 'to_ports' => [1], 'protocol' => 'tcp' }]) })
must_raise.call('port 0 rejected', -> { VALID_PROPS.merge('ufw.rules' => [{ 'description' => 'x', 'from' => ['10.0.0.0/8'], 'to_ports' => [0], 'protocol' => 'tcp' }]) })
must_raise.call('port 65536 rejected', -> { VALID_PROPS.merge('ufw.rules' => [{ 'description' => 'x', 'from' => ['10.0.0.0/8'], 'to_ports' => [65536], 'protocol' => 'tcp' }]) })
must_raise.call('inverted range rejected', -> { VALID_PROPS.merge('ufw.rules' => [{ 'description' => 'x', 'from' => ['10.0.0.0/8'], 'to_ports' => ['400:399'], 'protocol' => 'tcp' }]) })
must_raise.call('bad protocol rejected', -> { VALID_PROPS.merge('ufw.rules' => [{ 'description' => 'x', 'from' => ['10.0.0.0/8'], 'to_ports' => [1], 'protocol' => 'icmp' }]) })
must_raise.call('quote in description rejected', -> { VALID_PROPS.merge('ufw.rules' => [{ 'description' => "it's", 'from' => ['10.0.0.0/8'], 'to_ports' => [1], 'protocol' => 'tcp' }]) })
must_raise.call('empty from rejected', -> { VALID_PROPS.merge('ufw.rules' => [{ 'description' => 'x', 'from' => [], 'to_ports' => [1], 'protocol' => 'tcp' }]) })
must_raise.call('ipv6 prefix >128 rejected', -> { VALID_PROPS.merge('ufw.rules' => [{ 'description' => 'x', 'from' => ['fe80::/129'], 'to_ports' => [1], 'protocol' => 'tcp' }]) })
must_raise.call('bad logging rejected', -> { VALID_PROPS.merge('ufw.logging' => 'paranoid') })

exit(failures.zero? ? 0 : 1)
