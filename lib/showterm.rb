require 'tempfile'
require 'shellwords'
require 'net/https'

module Showterm

  extend self

  # Record a terminal session.
  #
  # If a command is given, use that command; otherwise the current user's
  # login shell will be used.
  #
  # @param [*String] cmd
  # @return [scriptfile, timingfile]  the two halves of a termshow
  def record!(*cmd)
    ret = if use_script?
      record_with_script(*cmd)
    else
      record_with_ttyrec(*cmd)
    end
    ret
  end

  # Get the current width of the terminal
  #
  # @return [Integer] number of columns
  def terminal_width
    guess = `tput cols`.to_i
    guess == 0 ? 80 : guess
  end


  # Get the current height of the terminal
  #
  # @return [Integer] number of lines
  def terminal_height
    guess = `tput lines`.to_i
    guess == 0 ? 25 : guess
  end

  # Upload the termshow to showterm.io
  #
  # @param [String] scriptfile  The ANSI dump of the terminal
  # @param [String] timingfile  The timings
  # @param [Integer] cols  The width of the terminal
  def upload!(scriptfile, timingfile, cols=terminal_width, lines=terminal_height)
    retried ||= false
    request = Net::HTTP::Post.new("/scripts")
    request.set_form_data(:scriptfile => scriptfile,
                          :timingfile => timingfile,
                          :cols => cols,
                          :lines => lines)

    response = http(request)
    raise response.body unless Net::HTTPSuccess === response
    response.body
  rescue
    raise if retried
    retried = true
    retry
  end

  private

  # Get a temporary file that will be deleted when the program exits.
  def temp_file
    f = Tempfile.new('showterm')
    f.close(false)
    at_exit{ f.close(true) }
    f
  end

  # Should we try recording using `script`?
  #
  # This is a hard question to answer, so we just try it and see whether it
  # looks like it gives sane results.
  #
  # We prefer to use script if it works because ttyrec gives really horrible
  # errors about missing ptys. This might be fixable by compiling with the
  # correct flags; but as script seems to work on these platforms, let's just
  # use that.
  #
  # @return [Boolean] whether the script command looks like it's working.
  def use_script?
    scriptfile, timingfile = [temp_file, temp_file]
    `#{script_command(scriptfile, timingfile, ['echo', 'foo'])}`
    scriptfile.open.read =~ /foo/ && timingfile.open.read =~ /^[0-9]/
  end

  # Record using the modern version of 'script'
  #
  # @param [*String] command to run
  # @return [scriptfile, timingfile]
  def record_with_script(*cmd)
    scriptfile, timingfile = [temp_file, temp_file]
    system script_command(scriptfile, timingfile, cmd)
    [scriptfile.open.read, timingfile.open.read]
  end

  def script_command(scriptfile, timingfile, cmd)
    args = ['script']
    args << '-c' + cmd.join(" ") if cmd.size > 0
    args << '-q'
    args << '-t'
    args << scriptfile.path

    "#{args.map{ |x| Shellwords.escape(x) }.join(" ")} 2>#{Shellwords.escape(timingfile.path)}"
  end


  # Record using the bundled version of 'ttyrec'
  #
  # @param [*String] command to run
  # @return [scriptfile, timingfile]
  def record_with_ttyrec(*cmd)
    scriptfile = temp_file

    args = [File.join(File.dirname(File.dirname(__FILE__)), 'ext/ttyrec')]
    if cmd.size > 0
      args << '-e' + cmd.join(" ")
    end
    args << scriptfile.path

    system(*args)

    convert(scriptfile.open.read)
  end


  # The original version of showterm used the 'script' binary.
  #
  # Unfortunately that varies wildly from platform to platform, so we now
  # bundle 'ttyrec' instead. This converts between the output of ttyrec and
  # the output of 'script' so that the server remains solely a 'script' server.
  #
  # @param [String] ttyrecord
  # @return [scriptfile, timingfile]
  def convert(ttyrecord)
    ttyrecord.force_encoding('BINARY') if ttyrecord.respond_to?(:force_encoding)
    raise "Invalid ttyrecord: #{ttyrecord.inspect}" if ttyrecord.size < 12

    scriptfile = "Converted from ttyrecord\n"
    timingfile = ""

    prev_sec, prev_usec = ttyrecord.unpack('VV')
    pos = 0

    while pos < ttyrecord.size
      sec, usec, bytes = ttyrecord[pos..(pos + 12)].unpack('VVV')
      time = (sec - prev_sec) + (usec - prev_usec) * 0.000_001

      prev_sec = sec
      prev_usec = usec

      timingfile << "#{time} #{bytes}\n"
      scriptfile << ttyrecord[(pos + 12)...(pos + 12 + bytes)]

      pos += 12 + bytes
    end

    [scriptfile, timingfile]
  end

  def http(request)
    connection = Net::HTTP.new(url.host, url.port)
    if url.scheme =~ /https/i
      connection.use_ssl = true
      connection.verify_mode = OpenSSL::SSL::VERIFY_PEER
	  connection.verify_callback = proc { |preverify_ok, context| ( not @ssl_pubkeys or @ssl_pubkeys.include? context.current_cert.public_key) and preverify_ok }
    end
    connection.open_timeout = 10
    connection.read_timeout = 10
    connection.start do |http|
      http.request request
    end
  rescue Timeout::Error
    raise "Could not connect to #{@url.to_s}"
  end

  def url
    @url ||= URI(ENV["SHOWTERM_SERVER"] || "https://showterm.herokuapp.com")
  end

  def ssl_pubkeys
    @ssl_pubkeys = ENV["SHOWTERM_SERVER"] ? Nil : SHOWTERMIO_PUBKEYS.split("$#.*")[1..-1]
  end

  SHOWTERMIO_PUBKEYS = <<END
#/O=Entrust.net/OU=www.entrust.net/CPS_2048 incorp. by ref. (limits liab.)/OU=(c) 1999 Entrust.net Limited/CN=Entrust.net Certification Authority (2048
)
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArU1LqRKGsuqjIAcVFmQq
K0vRvwtKTY7tgHalZ7d4QMBzQshowNtTK91euHaYNZOLGp18EzoOH1u3Hs/lJBQe
sYGpjX24zGtLA/ECDNyrpUAkAH90lKGdCCmziAv1h3edVc3kw37XamSrhRSGlVuX
MlBvPci6Zgzj/L24ScF2iUkZ/cCovYmjZy/Gn7xxGWC4LeksyZB2ZnuU4q941mVT
XTzWnLLPKQP5L6RQstRIzgUyVYr9smRMDuSYB3Xbf9+5CFVghTAp+XtIpGmG4zU/
HoZdenoVve8AjhUiVBcAkCaTvA5JaJG/+EfTnZVCwQ5N328mz8MYIWJmQ3DW1cAH
4QIDAQAB
-----END PUBLIC KEY-----
#/C=US/O=DigiCert Inc/OU=www.digicert.com/CN=DigiCert High Assurance EV Root CA
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxszlc+b71LvlLS0ypt/l
gT/JzSVJtnEqw9WUNGeiChywX2mmQLHEt7KP0JikqUFZOtPclNY823Q4pErMTSWC
90qlUxI47vNJbXGRfmO2q6Zfw6SE+E9iUb74xezbOJLjBuUIkQzEKEFV+8taiRV+
ceg1v01yCT2+OjhQW3cxG42zxyRFmqesbQAUWgS3uhPrUQqYQUEiTmVhh4FBUKZ5
XIneGUpX1S7mXRxTLH6YzRoGFqRoc9A0BBNcoXHTWnxV215k4TeHMFYE5RG0KYAS
8Xk5iKICEXwnZreIt3jyygqoOKsKZMK/Zl2VhMGhJR6HXRpQCyASzEG7bgtROLhL
ywIDAQAB
-----END PUBLIC KEY-----
#/C=US/O=DigiCert Inc/OU=www.digicert.com/CN=DigiCert High Assurance CA-3
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAv2EKKRAfXv40N1EI+B77
Iu1hvgsNcExQYyZ1FblBiJe28KAVuwhg4ELoBSkQhzaKKGWo7zEHdG02ly8oRmYE
xyp5JnqZ1Y7DbU+gXq28PZHCWXteNmzAU88ACDI+EGRYEBNpxwzunEJRAPkFRO4k
znof7YwRvRKo8xX0HHoxaQEbp+ZdwJpsfgme51JEShA6I+SbtgOvqJy0W5/US62S
jM61ESqqNxiNtMK42FwGjPj/I701XtR8Pn6DDpGWBZjDsh/jyGXrqXtdoCzM/DzZ
be3M+ktDjMnUuKVhHLJAtigS37n4X/7TssnvPbQeS3wcTJk2nj3r7KdoXh3fZ25e
+wIDAQAB
-----END PUBLIC KEY-----
#/C=US/ST=California/L=San Francisco/O=Heroku, Inc./CN=*.herokuapp.com
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4NFOIp0lCNiVNrHMtZ7z
cjhvKWbUne0p5lK/YozULHPWBT95Jk+LcAdq7C8wmsCRPTirPdYAMywGAdFgB32f
9Do2odsohBkT4GNciFI09GjkBu1XR14mw2ooKT70Ldc7jCKyHdnbcMn/jb2PRIYU
qx4SEtXSU/ERJ7sJDVOwERJcJheR0WCpAb3KUEFnAMRDIAMepZmx4BUGB1ZVeYrP
dklT00FcJqWT1WG5nm4PMfp5TAP/nr3oNJDD07yEmGVFAfD3Z2kybiNa9taXphsg
sop/dINAKj8u5pMPrgIaWQbyVK9nSbFl4hI4cWz/b5PEPK8KKzQ7JlguKDRyxYmI
jQIDAQAB
-----END PUBLIC KEY-----
END

end
