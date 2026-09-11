# frozen_string_literal: true

require 'json'
require 'redis'

module ExternalCatalog
  # Persists + broadcasts catalog-import progress for the overlay (ActionCable + poll).
  class ImportProgress
    CACHE_PREFIX = 'external_catalog_import'.freeze
    DEFAULT_TTL = 12.hours
    STREAM_PREFIX = 'external_catalog_import'.freeze

    # Ordered steps shown in the import overlay until the analysis view opens.
    STEPS = [
      { key: 'queued', label: 'Queued' },
      { key: 'downloading', label: 'Downloading dataset' },
      { key: 'preparsing', label: 'Preparsing file' },
      { key: 'creating_project', label: 'Creating project' },
      { key: 'linking_project', label: 'Linking existing project' },
      { key: 'opening', label: 'Opening analysis' }
    ].freeze

    STEP_KEYS = STEPS.map { |s| s[:key] }.freeze

    STEP_MESSAGES = {
      'queued' => 'Import queued...',
      'downloading' => 'Downloading dataset...',
      'preparsing' => 'Preparsing file...',
      'creating_project' => 'Creating project...',
      'linking_project' => 'Linking existing project...',
      'opening' => 'Opening analysis...',
      'failed' => 'Import failed.'
    }.freeze

    class << self
      def stream_name(candidate_id)
        "#{STREAM_PREFIX}_#{candidate_id}"
      end

      def key(candidate_id)
        "#{CACHE_PREFIX}:#{candidate_id}"
      end

      def read(candidate_id)
        return nil if candidate_id.blank?

        if redis_available?
          raw = redis.get(key(candidate_id))
          raw ? JSON.parse(raw) : nil
        else
          Rails.cache.read(key(candidate_id))
        end
      rescue JSON::ParserError
        nil
      end

      def clear(candidate_id)
        return if candidate_id.blank?

        if redis_available?
          redis.del(key(candidate_id))
        else
          Rails.cache.delete(key(candidate_id))
        end
      end

      # Writes the latest payload and broadcasts to ActionCable subscribers.
      def report(candidate_id, step:, message: nil, **extra)
        return if candidate_id.blank?

        step = step.to_s
        previous = read(candidate_id) || {}
        completed =
          if step == 'failed'
            Array(previous['steps_completed']).map(&:to_s)
          else
            merge_completed_steps(previous, step)
          end

        payload = {
          'candidate_id' => candidate_id.to_i,
          'import_status' => step == 'failed' ? 'failed' : 'importing',
          'step' => step,
          'message' => message.presence || STEP_MESSAGES[step] || step.to_s.humanize,
          'steps_completed' => completed,
          'steps' => STEPS
        }
        %w[import_error project_url project_key].each do |field|
          payload[field] = previous[field] if previous.key?(field)
        end
        # Keep download transfer fields only while still downloading; otherwise polls
        # would keep resurrecting a finished transfer bar.
        if step == 'downloading'
          %w[transfer_progress transfer_downloaded transfer_total].each do |field|
            payload[field] = previous[field] if previous.key?(field)
          end
        end
        extra.each { |k, v| payload[k.to_s] = v }

        write(candidate_id, payload)
        ActionCable.server.broadcast(stream_name(candidate_id), payload)
        payload
      end

      def report_download(candidate_id, downloaded:, total:)
        downloaded = downloaded.to_i
        total = total.to_i
        total = nil if total <= 0
        transfer_progress =
          if total.to_i.positive?
            ((downloaded.to_f / total) * 100).round
          end

        report(
          candidate_id,
          step: 'downloading',
          message: 'Downloading dataset...',
          transfer_progress: transfer_progress,
          transfer_downloaded: downloaded,
          transfer_total: total
        )
      end

      private

      def write(candidate_id, payload, expires_in: DEFAULT_TTL)
        if redis_available?
          redis.setex(key(candidate_id), expires_in.to_i, payload.to_json)
        else
          Rails.cache.write(key(candidate_id), payload, expires_in: expires_in)
        end
      end

      def merge_completed_steps(previous, current_step)
        completed = Array(previous['steps_completed']).map(&:to_s)
        last = previous['step'].to_s
        if last.present? && last != current_step && last != 'failed'
          completed |= [last]
        end

        if current_step == 'creating_project' || completed.include?('creating_project')
          completed -= ['linking_project']
        end
        if current_step == 'linking_project' || completed.include?('linking_project')
          completed -= ['creating_project']
        end

        completed.uniq
      end

      def redis_available?
        redis.present?
      rescue StandardError
        false
      end

      def redis
        @redis ||= Redis.new(url: ENV.fetch('REDIS_URL'))
      end
    end
  end
end
