# Slurm pending-queue copy for any run (HTTP JSON, Action Cable, tooltips).
class MarkerQueueText
  # User-visible explanation when Slurm cannot place the job (node down, slurmd stopped, etc.).
  def self.blocker_message(snap: nil, reason: nil)
    reason = reason.presence || snap&.dig(:reason).presence
    cluster = snap&.dig(:cluster) if snap.is_a?(Hash)

    if reason&.match?(/ReqNodeNotAvail|UnavailableNodes/i) || cluster&.dig(:all_down)
      nodes = cluster&.dig(:down_names)&.join(', ')
      node_bit = nodes.present? ? " (#{nodes})" : ''
      return "Compute node unavailable#{node_bit}: the Slurm compute daemon (slurmd) is not running or the node is down. " \
        "On the server host run: sudo systemctl enable --now slurmd — then confirm with sinfo that the node is idle."
    end

    if reason&.match?(/DOWN|DRAINED|Not responding/i) || cluster&.dig(:any_down)
      return "Slurm compute node is down or not responding. Jobs will stay queued until slurmd is started on the host " \
        "(sudo systemctl enable --now slurmd)."
    end

    return nil if reason.blank?

    "Slurm pending reason: #{reason}"
  end

  # Short line for title/tooltip on waiting icons (hover).
  def self.hover_summary(snap, queue_position)
    blocker = blocker_message(snap: snap)
    if blocker.present?
      return blocker
    end

    if snap.is_a?(Hash)
      part = snap[:partition].to_s
      tot = snap[:pending_count].to_i
      pos = snap[:position].to_i
      if tot <= 1
        "Slurm queue position: only pending job in partition #{part} (cluster-wide list)."
      else
        "Slurm queue position: about #{pos} of #{tot} pending jobs in partition #{part} (cluster-wide)."
      end
    elsif !queue_position.nil?
      if queue_position.to_i.zero?
        "Slurm queue position: no other pending jobs ahead in this Slurm partition (cluster-wide list)."
      else
        "Slurm queue position: #{queue_position}."
      end
    end
  end

  def self.partition_pending_explanation(snap)
    return nil unless snap.is_a?(Hash)

    part = snap[:partition].to_s
    tot = snap[:pending_count].to_i
    pos = snap[:position].to_i
    queue_note =
      if tot <= 1
        "In Slurm partition #{part}, this job is currently the only one in the pending queue. " \
          "That is the full pending list for this partition (all users and projects), not a count of metadata columns and not only this project."
      else
        "In Slurm partition #{part}, this job is about #{pos} of #{tot} pending jobs. " \
          "The #{tot} figure is every pending job in that partition (cluster-wide for that queue), not per metadata column and not only this project."
      end
    queue_note += " Pending means Slurm has not assigned this job to a compute node yet. " \
      "You can see no running jobs and still be pending: placement depends on CPUs, memory, partition or QOS limits, and node state, not only on other jobs being ahead in the queue."
    blocker = blocker_message(snap: snap)
    queue_note += " #{blocker}" if blocker.present?
    queue_note
  end
end
