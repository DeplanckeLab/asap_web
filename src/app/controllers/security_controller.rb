class SecurityController < ApplicationController
  skip_before_action :authenticate_user!, only: [:solve_session_cookie_challenge], raise: false

  def solve_session_cookie_challenge
    ip = request.remote_ip.to_s
    nonce = params[:nonce].to_s
    click_x = params[:x]
    click_y = params[:y]

    solved = SessionCookieGate.solve_challenge!(
      ip,
      nonce: nonce,
      click_x: click_x,
      click_y: click_y
    )

    if solved
      SessionCookieGateAuditLogger.unban!(ip: ip, source: 'puzzle')
      Fail2banBridge.unban_ip(ip)
      render json: { ok: true, message: 'IP unbanned successfully. Please retry your request.' }, status: :ok
    else
      render json: { ok: false, message: 'Puzzle verification failed. Please try again.' }, status: :unprocessable_entity
    end
  end
end
