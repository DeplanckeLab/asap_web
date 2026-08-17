# frozen_string_literal: true

require 'test_helper'

class RunErrorMailerTest < ActionMailer::TestCase
  setup do
    @previous_host = ENV['HOST']
    @previous_instance_name = ENV['ASAP_INSTANCE_NAME']
    @previous_admin_emails = ENV['ADMIN_REPORT_EMAILS']
    ENV['HOST'] = 'asap-test.epfl.ch'
    ENV['ASAP_INSTANCE_NAME'] = 'asap_dev'
    ENV['ADMIN_REPORT_EMAILS'] = 'admin@example.com'

    @user = register_for_test_cleanup(
      User.create!(
        email: "errmail_#{SecureRandom.hex(4)}@example.com",
        password: 'password123',
        displayed_name: 'Error Reporter'
      )
    )
    @project = create_test_project!(user_id: @user.id)
    @step = Step.find_by(name: 'parsing')
    skip 'parsing step missing' unless @step
    waiting = Status.find_by(name: 'waiting')
    skip 'waiting status missing' unless waiting
    @run = register_for_test_cleanup(
      Run.create!(
        project_id: @project.id,
        step_id: @step.id,
        status_id: waiting.id,
        user_id: @user.id,
        error: 'boom'
      )
    )
  end

  teardown do
    set_or_delete_env('HOST', @previous_host)
    set_or_delete_env('ASAP_INSTANCE_NAME', @previous_instance_name)
    set_or_delete_env('ADMIN_REPORT_EMAILS', @previous_admin_emails)
  end

  test 'user_report includes instance and logged-in reporter' do
    email = RunErrorMailer.user_report(
      run: @run,
      sender_email: @user.email,
      reporter: @user
    )

    assert_equal ['admin@example.com'], email.to
    assert_includes email.subject, '[dev/test]'
    body = email.body.to_s
    assert_includes body, 'Instance:</strong> dev/test (asap-test.epfl.ch, asap_dev)'
    assert_includes body, "Logged-in user ##{@user.id} Error Reporter"
    assert_includes body, @user.email
    refute_includes body, 'Guest user'
    assert_includes body, "https://asap-test.epfl.ch/projects/#{@project.key}"
    refute_includes body, 'localhost'
  end

  test 'user_report includes X-Real-IP' do
    email = RunErrorMailer.user_report(
      run: @run,
      sender_email: @user.email,
      reporter: @user,
      x_real_ip: '203.0.113.10'
    )

    assert_includes email.body.to_s, 'X-Real-IP:</strong> 203.0.113.10'
  end

  test 'user_report marks guest reporter' do
    email = RunErrorMailer.user_report(
      run: @run,
      sender_email: 'guest@example.com',
      reporter: nil
    )

    body = email.body.to_s
    assert_includes body, 'Guest user'
    refute_includes body, 'Logged-in user'
    assert_includes body, 'guest@example.com'
  end

  test 'admin_notification includes production instance in subject and body' do
    ENV['HOST'] = 'asap.epfl.ch'
    ENV['ASAP_INSTANCE_NAME'] = 'asap'
    email = RunErrorMailer.admin_notification(run: @run)

    assert_includes email.subject, '[production]'
    body = email.body.to_s
    assert_includes body, 'Instance:</strong> production (asap.epfl.ch, asap)'
    assert_includes body, "https://asap.epfl.ch/projects/#{@project.key}"
    refute_includes body, 'localhost'
  end

  private

  def set_or_delete_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end
