# This migration comes from hyrax (originally 20170504192714)
class ChangeChecksumAuditLog < ActiveRecord::Migration
  def change
    rename_column :checksum_audit_logs, :version, :checked_uri
    add_column    :checksum_audit_logs, :passed, :boolean

    reversible do |dir|
      dir.up do
        ChecksumAuditLog.find_each { |log| log.update!(passed: log.pass ) }
      end
      dir.down do
        ChecksumAuditLog.find_each { |log| log.update!(pass: log.passed ) }
      end
    end

    remove_column :checksum_audit_logs, :pass
    add_index     :checksum_audit_logs, :checked_uri
  end
end

