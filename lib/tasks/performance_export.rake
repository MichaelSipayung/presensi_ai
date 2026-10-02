require 'csv'

namespace :performance do
  desc "Ekspor PerformanceLog ke CSV untuk analisis (bab hasil skripsi)"
  task export: :environment do
    path = Rails.root.join('tmp', "performance_log_#{Time.now.strftime('%Y%m%d_%H%M%S')}.csv")

    CSV.open(path, 'w') do |csv|
      csv << [
        'id', 'event_type', 'used_fallback', 'probe_candidate_count',
        'fallback_candidate_count', 'probe_time_ms', 'fallback_time_ms',
        'total_time_ms', 'best_similarity', 'match_found', 'created_at'
      ]
      PerformanceLog.order(:created_at).find_each do |log|
        csv << [
          log.id, log.event_type, log.used_fallback, log.probe_candidate_count,
          log.fallback_candidate_count, log.probe_time_ms, log.fallback_time_ms,
          log.total_time_ms, log.best_similarity, log.match_found, log.created_at
        ]
      end
    end

    puts "[SUKSES] Diekspor ke #{path}"
  end

  desc "Ringkasan statistik cepat di terminal (tanpa perlu buka CSV)"
  task summary: :environment do
    %w[attendance registration_dedup].each do |event|
      logs = PerformanceLog.where(event_type: event)
      next if logs.empty?

      total = logs.count
      fallback_count = logs.where(used_fallback: true).count
      fallback_rate = (fallback_count.to_f / total * 100).round(2)

      avg_total_time = logs.average(:total_time_ms)&.round(4)
      avg_probe_time = logs.average(:probe_time_ms)&.round(4)
      avg_fallback_time = logs.where(used_fallback: true).average(:fallback_time_ms)&.round(4)

      puts "\n=== #{event.upcase} ==="
      puts "Total percobaan       : #{total}"
      puts "Fallback terpicu      : #{fallback_count} (#{fallback_rate}%)"
      puts "Rata-rata waktu total : #{avg_total_time} ms"
      puts "Rata-rata waktu probe : #{avg_probe_time} ms"
      puts "Rata-rata waktu fallback (jika terpicu): #{avg_fallback_time || 'N/A'} ms"
    end
  end
end
