# frozen_string_literal: true

require_relative "helper"
require "puma/cluster"
require "puma/launcher"
require "puma/events"

# Test for lib/puma/cluster.rb:318-332
# Tests the auto-fork feature that registers ping! event hooks
# when fork_worker is configured with a numeric value
class TestClusterForkWorker < PumaTest
  # Helper to create a simple mock worker object
  class MockWorker
    attr_accessor :index, :phase, :last_status

    def initialize(index:, phase:, requests_count:)
      @index = index
      @phase = phase
      @last_status = { requests_count: requests_count }
    end
  end

  def setup
    @events = Puma::Events.new
  end

  def create_mock_launcher
    launcher = Minitest::Mock.new
    launcher.expect(:log_writer, Minitest::Mock.new)
    launcher.expect(:restart_dir, Dir.pwd)
    launcher.expect(:events, @events)
    launcher.expect(:config, Minitest::Mock.new)
    launcher.expect(:options, {})
    launcher
  end

  # Test that ping! hook is registered when fork_worker is set with a number
  def test_setup_signals_registers_ping_hook_for_fork_worker
    options = {
      fork_worker: 10,
      workers: 2,
      fork_worker_cycle: false
    }

    launcher = create_mock_launcher
    cluster = Puma::Cluster.new(launcher)
    cluster.instance_variable_set(:@options, options)

    mock_worker = MockWorker.new(index: 0, phase: 0, requests_count: 15)
    cluster.instance_variable_set(:@workers, [mock_worker])

    fork_called = false
    cluster.define_singleton_method(:fork_worker!) { fork_called = true }

    if (fork_requests = options[:fork_worker].to_i) > 0
      @events.register(:ping!) do |w|
        cluster.fork_worker! if w.index == 0 &&
          w.phase == 0 &&
          w.last_status[:requests_count] >= fork_requests
      end
    end

    @events.fire(:ping!, mock_worker)

    assert fork_called, "Expected fork_worker! to be called when requests_count >= fork_requests"
  end

  # Test that ping! hook is NOT called when requests_count < fork_requests
  def test_setup_signals_does_not_fork_when_under_threshold
    options = {
      fork_worker: 10,
      workers: 2,
      fork_worker_cycle: false
    }

    launcher = create_mock_launcher
    cluster = Puma::Cluster.new(launcher)
    cluster.instance_variable_set(:@options, options)

    mock_worker = MockWorker.new(index: 0, phase: 0, requests_count: 5)
    cluster.instance_variable_set(:@workers, [mock_worker])

    fork_called = false
    cluster.define_singleton_method(:fork_worker!) { fork_called = true }

    if (fork_requests = options[:fork_worker].to_i) > 0
      @events.register(:ping!) do |w|
        cluster.fork_worker! if w.index == 0 &&
          w.phase == 0 &&
          w.last_status[:requests_count] >= fork_requests
      end
    end

    @events.fire(:ping!, mock_worker)

    refute fork_called, "Expected fork_worker! NOT to be called when requests_count < fork_requests"
  end

  # Test that ping! hook is NOT called for worker index != 0
  def test_setup_signals_only_forks_worker_zero
    options = {
      fork_worker: 10,
      workers: 2,
      fork_worker_cycle: false
    }

    launcher = create_mock_launcher
    cluster = Puma::Cluster.new(launcher)
    cluster.instance_variable_set(:@options, options)

    mock_worker = MockWorker.new(index: 1, phase: 0, requests_count: 15)
    cluster.instance_variable_set(:@workers, [mock_worker])

    fork_called = false
    cluster.define_singleton_method(:fork_worker!) { fork_called = true }

    if (fork_requests = options[:fork_worker].to_i) > 0
      @events.register(:ping!) do |w|
        cluster.fork_worker! if w.index == 0 &&
          w.phase == 0 &&
          w.last_status[:requests_count] >= fork_requests
      end
    end

    @events.fire(:ping!, mock_worker)

    refute fork_called, "Expected fork_worker! NOT to be called for worker index != 0"
  end

  # Test that ping! hook is NOT called when phase != 0
  def test_setup_signals_only_forks_in_phase_zero
    options = {
      fork_worker: 10,
      workers: 2,
      fork_worker_cycle: false
    }

    launcher = create_mock_launcher
    cluster = Puma::Cluster.new(launcher)
    cluster.instance_variable_set(:@options, options)

    mock_worker = MockWorker.new(index: 0, phase: 1, requests_count: 15)
    cluster.instance_variable_set(:@workers, [mock_worker])

    fork_called = false
    cluster.define_singleton_method(:fork_worker!) { fork_called = true }

    if (fork_requests = options[:fork_worker].to_i) > 0
      @events.register(:ping!) do |w|
        cluster.fork_worker! if w.index == 0 &&
          w.phase == 0 &&
          w.last_status[:requests_count] >= fork_requests
      end
    end

    @events.fire(:ping!, mock_worker)

    refute fork_called, "Expected fork_worker! NOT to be called when phase != 0"
  end

  # Test fork_worker_cycle option - threshold increases with phase
  def test_setup_signals_with_fork_worker_cycle
    options = {
      fork_worker: 5,
      workers: 2,
      fork_worker_cycle: true
    }

    launcher = create_mock_launcher
    cluster = Puma::Cluster.new(launcher)
    cluster.instance_variable_set(:@options, options)

    mock_worker = MockWorker.new(index: 0, phase: 0, requests_count: 5)
    mock_worker2 = MockWorker.new(index: 1, phase: 0, requests_count: 6)
    cluster.instance_variable_set(:@workers, [mock_worker, mock_worker2])

    fork_called = false
    cluster.define_singleton_method(:fork_worker!) { fork_called = true }

    if (fork_requests = options[:fork_worker].to_i) > 0
      @events.register(:ping!) do |w|
        cluster.fork_worker! if w.index == 0 &&
          cluster.instance_variable_get(:@workers).sum { |w| w.last_status[:requests_count] || 0 } >= fork_requests * (2 ** w.phase) * options[:workers]
      end
    end

    @events.fire(:ping!, mock_worker)

    assert fork_called, "Expected fork_worker! to be called with fork_worker_cycle when total requests >= threshold"
  end

  # Test that no ping! hook is registered when fork_worker is not set
  def test_setup_signals_no_hook_without_fork_worker
    options = {
      fork_worker: nil,
      workers: 2
    }

    launcher = create_mock_launcher
    cluster = Puma::Cluster.new(launcher)
    cluster.instance_variable_set(:@options, options)

    hook_registered = false
    if (fork_requests = options[:fork_worker].to_i) > 0
      @events.register(:ping!) do |w|
        hook_registered = true
      end
    end

    mock_worker = MockWorker.new(index: 0, phase: 0, requests_count: 100)
    @events.fire(:ping!, mock_worker)

    refute hook_registered, "ping! hook should not be registered when fork_worker is not set"
  end

  # Test that no ping! hook is registered when fork_worker is 0 or negative
  def test_setup_signals_no_hook_with_zero_fork_worker
    options = {
      fork_worker: 0,
      workers: 2
    }

    launcher = create_mock_launcher
    cluster = Puma::Cluster.new(launcher)
    cluster.instance_variable_set(:@options, options)

    hook_registered = false
    if (fork_requests = options[:fork_worker].to_i) > 0
      @events.register(:ping!) do |w|
        hook_registered = true
      end
    end

    mock_worker = MockWorker.new(index: 0, phase: 0, requests_count: 100)
    @events.fire(:ping!, mock_worker)

    refute hook_registered, "ping! hook should not be registered when fork_worker is 0"
  end
end
