##! A module for performing active HTTP requests and
##! getting the reply at runtime.

@load /usr/share/bro/base/utils/exec.bro

module ActiveHTTP2;

export {
	## The default timeout for HTTP requests.
	const default_max_time = 1min &redef;

	## The default HTTP method/verb to use for requests.
	const default_method = "GET" &redef;

	type Response: record {
		## Numeric response code from the server.
		code:      count;
		## String response message from the server.
		msg:       string;
		## File name of the body of the response.
		bodyfile:      string                  &optional;
		## All headers returned by the server.
		headers:   table[string] of string &optional;
		## stdout
		stdout:    vector of string &optional;
		## stderr
		stderr:    vector of string &optional;
	};

	type Request: record {
		## The URL being requested.
		url:             string;
		## The HTTP method/verb to use for the request.
		method:          string                  &default=default_method;
		## Data to send to the server in the client body.  Keep in
		## mind that you will probably need to set the *method* field
		## to "POST" or "PUT".
		client_data:     string                  &optional;

		# The filename to store the response body in
		bodyfile:	string	&optional;

		# Arbitrary headers to pass to the server.  Some headers
		# will be included by libCurl.
		#custom_headers: table[string] of string &optional;

		## Timeout for the request.
		max_time:        interval                &default=default_max_time;
		## Additional curl command line arguments.  Be very careful
		## with this option since shell injection could take place
		## if careful handling of untrusted data is not applied.
		addl_curl_args:  string                  &optional;
	};

	## Perform an HTTP request according to the
	## :bro:type:`ActiveHTTP2::Request` record.  This is an asynchronous
	## function and must be called within a "when" statement.
	##
	## req: A record instance representing all options for an HTTP request.
	##
	## Returns: A record with the full response message.
	global request: function(req: ActiveHTTP2::Request): ActiveHTTP2::Response;
}

function request2curl(r: Request, bodyfile: string, headersfile: string): string
	{
	local cmd = fmt("curl -s -g -o \"%s\" -D \"%s\" -X \"%s\"",
	                str_shell_escape(bodyfile),
	                str_shell_escape(headersfile),
	                str_shell_escape(r$method));

	cmd = fmt("%s -m %.0f", cmd, r$max_time);

	if ( r?$client_data )
		cmd = fmt("%s -d -", cmd);

	if ( r?$addl_curl_args )
		cmd = fmt("%s %s", cmd, r$addl_curl_args);

	cmd = fmt("%s \"%s\"", cmd, str_shell_escape(r$url));

	print fmt("< request2curl(): %s",cmd);
	return cmd;
	}

function request(req: Request): ActiveHTTP2::Response
	{
	local tmpfile     = "/tmp/bro-activehttp-" + unique_id("");
	local bodyfile :string;
	if (req?$bodyfile) {
		bodyfile = req$bodyfile;
	} else {
		bodyfile = fmt("%s_body", tmpfile);
	}
	local headersfile = fmt("%s_headers", tmpfile);

	local cmd = request2curl(req, bodyfile, headersfile);
	local stdin_data = req?$client_data ? req$client_data : "";

	local resp: Response;
	resp$code = 0;
	resp$msg = "";
	resp$bodyfile = bodyfile;
	resp$headers = table();
	return when ( local result = Exec::run([$cmd=cmd, $stdin=stdin_data, $read_files=set(headersfile)]) )
		{
		print "--- ActiveHTTP2::request() when ---";

		if (result?$stdout) resp$stdout = result$stdout;
		if (result?$stderr) resp$stderr = result$stderr;

		# If there is no response line then nothing else will work either.
		if ( ! (result?$files && headersfile in result$files) )
			{
			Reporter::error(fmt("There was a failure when requesting \"%s\" with ActiveHTTP2.", req$url));
			return resp;
			}

		local headers = result$files[headersfile];
		for ( i in headers )
			{
			# The reply is the first line.
			if ( i == 0 )
				{
				local response_line = split_n(headers[0], /[[:blank:]]+/, F, 2);
				if ( |response_line| != 3 )
					return resp;

				resp$code = to_count(response_line[2]);
				resp$msg = response_line[3];
				}
			else
				{
				local line = headers[i];
				local h = split1(line, /:/);
				if ( |h| != 2 )
					next;
				resp$headers[h[1]] = sub_bytes(h[2], 0, |h[2]|-1);
				}
			}
		return resp;
		}
	}
