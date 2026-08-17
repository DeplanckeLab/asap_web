class SecurityController < ApplicationController
  skip_before_action :authenticate_user!, only: [:solve_session_cookie_challenge], raise: false

  def solve_session_cookie_challenge
    ip = request.remote_ip.to_s
    nonce = params[:nonce].to_s
    drop_col = params[:drop_col]
    drop_row = params[:drop_row]

    solved = SessionCookieGate.solve_challenge!(
      ip,
      nonce: nonce,
      drop_col: drop_col,
      drop_row: drop_row
    )

    if solved
      grant_session_clearance!
      SessionCookieGateAuditLogger.unban!(ip: ip, source: 'puzzle')
      Fail2banBridge.unban_ip(ip)
      render json: { ok: true, message: 'Verification successful. You will not be asked again during this session.' }, status: :ok
    else
      render json: { ok: false, message: 'Puzzle verification failed. Please try again.' }, status: :unprocessable_entity
    end
  end
end
