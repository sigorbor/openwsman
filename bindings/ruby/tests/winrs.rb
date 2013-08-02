# create_shell.rb

#
# Create a remote window shell
#

require 'rexml/document'
require 'openwsman'

def handle_fault result
end

#  client = Openwsman::Client.new( "10.120.5.37", 5985, "/wsman", "http", "wsman", "secret")
  client = Openwsman::Client.new( "192.168.1.57", 5985, "/wsman", "http", "wsman", "secret")
  client.transport.timeout = 120
  client.transport.auth_method = Openwsman::BASIC_AUTH_STR
  # https
  # client.transport.verify_peer = 0
  # client.transport.verify_host = 0

  options = Openwsman::ClientOptions.new
  options.set_dump_request
  Openwsman::debug = -1
  options.timeout = 60 * 1000 # 60 seconds
  uri = "http://schemas.microsoft.com/wbem/wsman/1/windows/shell/cmd"

  service = "Themes"
  options.add_selector( "Name", service )
    
  options.options = { "WINRS_NOPROFILE" => "FALSE", "WINRS_CODEPAGE" => 437 }
    
  # instance values
  instance = { "InputStreams" => "stdin", "OutputStreams" => "stdout stderr" }

  namespace = "http://schemas.microsoft.com/wbem/wsman/1/windows/shell"
  data = Openwsman::XmlDoc.new("Shell", namespace)
  root = data.root
  instance.each do |key,value|
    root.add namespace, key, value
  end
    
  s = data.to_xml
  result = client.create( options, uri, s, s.size, "utf-8" )
  # returns something like
  #  <s:Body>
  #    <x:ResourceCreated>
  #      <a:Address>http://10.120.5.37:5985/wsman</a:Address>
  #      <a:ReferenceParameters>
  #        <w:ResourceURI>http://schemas.microsoft.com/wbem/wsman/1/windows/shell/cmd</w:ResourceURI>
  #        <w:SelectorSet>
  #          <w:Selector Name="ShellId">3D5D8879-98EA-49B7-9A33-6842EC0D35D0</w:Selector>
  #        </w:SelectorSet>
  #      </a:ReferenceParameters>
  #    </x:ResourceCreated>
  #  </s:Body>
  handle_fault result if result.fault?

  shell_id = result.find(nil, "Selector")
  raise "No shell id returned" unless shell_id
  puts "Shell ID: #{shell_id}"
  
  loop do
    print "WinRS> "
    STDOUT.flush
    cmd = gets
    break if cmd.nil?
    cmd.chomp!
    next if cmd.empty?
    
    # issue command
    options.options = { "WINRS_CONSOLEMODE_STDIN" => "TRUE", "WINRS_SKIP_CMD_SHELL" => "FALSE" }
    options.selectors = { "ShellId" => shell_id }
    data = Openwsman::XmlDoc.new("CommandLine", namespace)
    root = data.root
    root.add namespace, "Command", cmd
    result = client.invoke( options, uri, "http://schemas.microsoft.com/wbem/wsman/1/windows/shell/Command", data)
    handle_fault result if result.fault?
    command_id = result.find(namespace, "CommandId")
    raise "No command id returned" unless command_id
    command_id = command_id.text
#    puts "Command ID: #{command_id}"

    # receive stdout/stderr
    options.options = { }
    # keep ShellId selector
    data = Openwsman::XmlDoc.new("Receive", namespace)
    root = data.root
    node = root.add namespace, "DesiredStream", "stdout stderr"
    node.attr_add nil, "CommandId", command_id
    result = client.invoke( options, uri, "http://schemas.microsoft.com/wbem/wsman/1/windows/shell/Receive", data)
    handle_fault result if result.fault?
    response = result.find(namespace, "ReceiveResponse")
    unless response
      STDERR.puts "***Err: No ReceiveResponse in: #{result.to_xml}"
      next
    end
    response.each do |node|
      cmd_id = node.attr "CommandId"
      if cmd_id.nil?
	STDERR.puts "***Err: No CommandId in ReceiveResponse node: #{node.to_xml}"
	next
      end
      if cmd_id.value != command_id
	STDERR.puts "***Err: Wrong CommandId in ReceiveResponse node. Expected #{command_id}, found #{cmd_id.value}"
	next
      end
#      puts "Node: #{node.to_xml}"
      case node.name
      when "Stream"
	stream_name = node.attr "Name"
	unless stream_name
	  STDERR.puts "***Err: Stream node has no Name attribute: #{node.to_xml}"
	  next
	end
	stream_name = stream_name.value
	str = node.text.unpack('m')[0]
	case stream_name
	when "stdout"
	  puts str
	when "stderr"
	  STDERR.puts str
	else
	  STDERR.puts "***Err: Unknown stream name: #{stream_name}"
	end
      when "CommandState"
	state = node.attr "State"
	unless state
	  STDERR.puts "***Err: CommandState node has no State attribute: #{node.to_xml}"
	  next
	end
	if state.value == "http://schemas.microsoft.com/wbem/wsman/1/windows/shell/CommandState/Done"
	  exit_code = node.get "ExitCode"
	  if exit_code
	    puts "Exit code: #{exit_code.text}"
	  else
	    STDERR.puts "***Err: No exit code for 'done' command: #{node.to_xml}"
	  end
	else
	  STDERR.puts "***Err: Unknown command state: #{state.value}"
	end
      else
	STDERR.puts "***Err: Unknown receive response: #{node.to_xml}"
      end
    end # response.each
  end

  puts "terminate"
  
  puts "destroy"
  