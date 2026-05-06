# frozen_string_literal: true

require 'ipaddr'
require 'open3'
require 'timeout'

class Fail2banBridge
  EXECUTION_TIMEOUT_SECONDS = 5

  class << self
    def unban_ip(ip)
      execute_from_template(
        template: ENV['FAIL2BAN_UNBAN_COMMAND'].to_s,
        ip: ip,
        action: 'unban'
      )
    end

    private

    def execute_from_template(template:, ip:, action:)
      return true if template.blank?

      validated_ip = validate_ip!(ip)
      command = template.gsub('%{ip}', validated_ip)

      stdout, stderr, status = run_command(command)
      if status.success?
        Rails.logger.info("fail2ban_bridge_#{action}_ok ip=#{validated_ip} stdout=#{stdout.to_s.strip.inspect}")
        true
      else
        Rails.logger.warn("fail2ban_bridge_#{action}_failed ip=#{validated_ip} status=#{status.exitstatus} stderr=#{stderr.to_s.strip.inspect}")
        false
      end
    rescue StandardError => e
      Rails.logger.warn("fail2ban_bridge_#{action}_error ip=#{ip.inspect} error=#{e.class}:#{e.message}")
      false
    end

    def validate_ip!(ip)
      IPAddr.new(ip.to_s.strip).to_s
    rescue IPAddr::InvalidAddressError
      raise ArgumentError, "invalid IP for fail2ban bridge: #{ip.inspect}"
    end

    def run_command(command)
      Timeout.timeout(EXECUTION_TIMEOUT_SECONDS) do
        Open3.capture3(command)
      end
    end
  end
end
