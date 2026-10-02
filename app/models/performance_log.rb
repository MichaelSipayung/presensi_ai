# app/models/performance_log.rb
class PerformanceLog < ApplicationRecord
  belongs_to :matched_user, class_name: 'User', optional: true
end