# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OtelLogging::Configuration do
  around do |example|
    saved = ENV.to_h.slice('OTEL_COLORIZE', 'NO_COLOR')
    ENV.delete('OTEL_COLORIZE')
    ENV.delete('NO_COLOR')
    example.run
  ensure
    ENV.delete('OTEL_COLORIZE')
    ENV.delete('NO_COLOR')
    ENV.update(saved)
  end

  def rails_environment(name)
    stub_const('Rails', double(env: ActiveSupport::StringInquirer.new(name)))
  end

  it 'keeps standalone output uncolored, including before Rails loads' do
    hide_const('Rails')
    settings = described_class.new
    expect(settings.colorize).to be false
    rails_environment('development')
    expect(settings.colorize).to be true
  end

  it 'honors NO_COLOR in development' do
    rails_environment('development')
    ENV['NO_COLOR'] = '1'
    expect(described_class.new.colorize).to be false
  end

  it 'honors explicit environment overrides ahead of defaults and NO_COLOR' do
    rails_environment('production')
    ENV['NO_COLOR'] = '1'
    ENV['OTEL_COLORIZE'] = 'true'
    expect(described_class.new.colorize).to be true
    rails_environment('development')
    ENV['OTEL_COLORIZE'] = 'false'
    expect(described_class.new.colorize).to be false
  end

  it 'honors explicit configuration in both directions' do
    rails_environment('development')
    settings = described_class.new
    settings.colorize = false
    expect(settings.colorize).to be false
    ENV['NO_COLOR'] = '1'
    settings = described_class.new
    settings.colorize = true
    expect(settings.colorize).to be true
  end
end
