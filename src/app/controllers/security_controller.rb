class SecurityController < ApplicationController
  skip_before_action :authenticate_user!, only: [:solve_session_cookie_challenge, :sign_out_intent], raise: false
  skip_before_action :verify_authenticity_token, only: [:sign_out_intent]

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

  # Best-effort click beacon for session diagnostics. Does not change auth state.
  def sign_out_intent
    return head :no_content unless SessionDiagnosticsMiddleware.enabled?

    source = 'beacon'
    path = request.referer.to_s

    if request.content_mime_type&.json?
      body = JSON.parse(request.raw_post.to_s)
      source = body['source'].to_s.presence || source
      path = body['path'].to_s.presence || path
    else
      source = params[:source].to_s.presence || source
      path = params[:path].to_s.presence || path
    end

    client_key = SessionDiagnosticsMiddleware.record_sign_out_intent!(request, source: source)
    SessionDiagnosticsLogger.sign_out_intent!(
      source: source,
      path: path.to_s[0, 300],
      ip: request.remote_ip.to_s,
      request_id: request.request_id,
      client_key: client_key,
      ua: SessionDiagnosticsMiddleware.client_key_for(request).split(':', 2).last
    )
    head :no_content
  rescue JSON::ParserError
    head :no_content
  end
end
