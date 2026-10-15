module http1

pub const crlf = '\r\n'

// reason is the reason phrase for a status code (RFC 9110 names).
pub fn reason(status int) string {
	return match status {
		100 { 'Continue' }
		101 { 'Switching Protocols' }
		200 { 'OK' }
		201 { 'Created' }
		202 { 'Accepted' }
		204 { 'No Content' }
		206 { 'Partial Content' }
		301 { 'Moved Permanently' }
		302 { 'Found' }
		303 { 'See Other' }
		304 { 'Not Modified' }
		307 { 'Temporary Redirect' }
		308 { 'Permanent Redirect' }
		400 { 'Bad Request' }
		401 { 'Unauthorized' }
		403 { 'Forbidden' }
		404 { 'Not Found' }
		405 { 'Method Not Allowed' }
		406 { 'Not Acceptable' }
		408 { 'Request Timeout' }
		409 { 'Conflict' }
		410 { 'Gone' }
		411 { 'Length Required' }
		412 { 'Precondition Failed' }
		413 { 'Content Too Large' }
		414 { 'URI Too Long' }
		415 { 'Unsupported Media Type' }
		416 { 'Range Not Satisfiable' }
		417 { 'Expectation Failed' }
		422 { 'Unprocessable Content' }
		426 { 'Upgrade Required' }
		428 { 'Precondition Required' }
		429 { 'Too Many Requests' }
		431 { 'Request Header Fields Too Large' }
		500 { 'Internal Server Error' }
		501 { 'Not Implemented' }
		502 { 'Bad Gateway' }
		503 { 'Service Unavailable' }
		504 { 'Gateway Timeout' }
		505 { 'HTTP Version Not Supported' }
		else { 'Unknown' }
	}
}

pub fn write_status_line(mut out []u8, status int) {
	append_str(mut out, 'HTTP/1.1 ')
	append_int(mut out, status)
	out << ` `
	append_str(mut out, reason(status))
	append_str(mut out, crlf)
}

pub fn write_header(mut out []u8, name string, value string) {
	append_str(mut out, name)
	append_str(mut out, ': ')
	append_str(mut out, value)
	append_str(mut out, crlf)
}

// body_allowed is false for statuses that must not carry a body or a Content-Length.
pub fn body_allowed(status int) bool {
	return status >= 200 && status != 204 && status != 304
}
