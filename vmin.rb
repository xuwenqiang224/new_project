=begin

Author: Michael Tang, Joshua Tsai, Gerald Vogt

Revision History:
	2.1.1 - [MT] Update run_workload functions for ACP diagnostic
	2.1.0 - [MT] Integrate Xcaptan functions
	2.0.0 - [MT] Integrate application and voltage_smu module
	1.5.4 - [MT/G] Confirm multi diag tests working
	1.5.3 - [MT] Cleanup method restore clocks
	1.5.2 - [MT] Enable Diag Tests in workload and enable linux autostart
	1.5.1 - [MT] Enable Linux Vmin idle, next patch aim in diag build. 
    1.5.0 - [MT] Added Diesel(SP3) function, multi packges and dies allowed.
	1.4.0 - [MT] Added default clock storing, die and package selection
	1.3.7 -	[g] Added invalid workload formatting handling, custom task csv file naming, over voltage protection
	1.3.4 -	[g] Fixed xml workloads and tuned outputs
	1.3.0 -	[g] First fully function version with task csv, wombat and server ip required as args
	1.2.2 -	[g] Made state into a class
	1.1.2 Using watch_dog_client with multiplexed 
	1.1.1 [J] Argument functions, reset algorithm, data calibration & experimentation
	1.1.0 [MT] Initial Draft, voltage setting and reboot
=end		

require 'orclib'
require 'csv'
require 'pry'
require '../../orc_services/ruby_client/watch_dog_client.rb'
require_relative '../lib/application.rb'

include Orclib::MsgModule


SCRIPT_VERSION = '2.1.1'

class CharzState

	# attr_reader 
	attr_accessor :xcaptan, :voltage_module, :update_timeout, :diag_folder, :os_type, :client_ip, :max_voltage, :asic_package, :asic_die, :clock_name, :default_clock, :atitool_timeout, :clock_list, :adjust_clock, :task_file_name, :id, :server_ip, :wombat_ip, :workload_delay, :workload, :phase2_dur, :phase1_dur, :actual_voltage, :last_passing_voltage, :results, :results_header, :voltage_rail_name, :phase_number, :starting_voltage, :original_voltage, :current_row_number, :last_voltage, :current_voltage, :voltage_step, :debug, :verbose, :task_done, :diag_loops
	attr_reader :start_time
	 
	def initialize()
		@id = ""
		@voltage_rail_name = nil
		@voltage_step = 0.00625	#in Volts, Apu usually has this vstep
		@max_voltage = 1.2	#in Volts
		@last_passing_voltage = {}
		@original_voltage = {}
		@starting_voltage = nil
		@current_voltage = nil
		@actual_voltage = {}
		@current_row_number = nil	#needs to be persitent accross the whole duration
		@task_done = false
		@phase1_dur = nil
		@phase2_dur = nil
		@atitool_timeout = 2
		@adjust_clock = {}
		#add diag_loops by Kids
		@diag_loops = 1 
		
		@clock_list = [] # for nice formatting in result sheet
		@clock_name = []
		#define default clock restore
		@default_clock = {}
		
		#die and package define
		@asic_package = nil
		@asic_die = nil
		
		@phase_number = 0
		@task_file_name = "vmin_tasks.csv"
		@workload = nil
		@workload_delay = 10
		
		@start_time = Time.now
		@results = []
		@results_header = []
		
		@wombat_ip = nil
		@server_ip = nil
		@client_ip = nil
		
		@debug = false
		@verbose = false
		
		# Define OS type
		@os_type = nil
		@diag_folder = nil
		
		# timeout for state
		@update_timeout = nil
		
		# voltage module
		@voltage_module = nil
		
		# xcaptan enable
		@xcaptan = false
	end
	
	def to_s
		s = "Vrail: #{@voltage_rail_name}, Phase: #{@phase_number}, current_voltage: #{@current_voltage}"
		s += "\nDuration: #{duration()} Row: #{@current_row_number} "
	end
	
	def duration()
		return  Time.now - @start_time
	end
	
	def reset
		@start_time = Time.now
		@results = []
		@results_header = []
		@workload = nil
		@workload_delay = 10
		@phase_number = 0
		@last_passing_voltage = {}
		@original_voltage = {}
		@starting_voltage = nil
		@current_voltage = nil
		@actual_voltage = {}
		@adjust_clock = {}
		@clock_list = []
		@atitool_timeout = 2
		@clock_name = []
		@asic_package = nil
		@asic_die = nil
		@os = nil
		@update_timeout = nil
		@voltage_module = nil
		@xcaptan = false
		
	end
		
end

def clean_up
	# @todo, clean up object save, ..., remove auto start
	if $state.voltage_module == "atitool"
		putz "Restoring #{$state.voltage_rail_name} voltage to #{$state.original_voltage[state.asic_package]}"
		$t.set_package_voltage($state.voltage_rail_name,$state.original_voltage[$state.asic_package],$state.asic_package) unless $state.nil? ||  $state.voltage_rail_name.nil? || $state.original_voltage[$state.asic_package].nil?
	elsif $state.voltage_module == "smu"
		putz "Restoring #{$state.voltage_rail_name} voltage to #{$state.original_voltage[state.asic_package]}"
		$vlt.set_voltage_rail($state.voltage_rail_name, $state.original_voltage[state.asic_package]) unless $state.nil? ||  $state.voltage_rail_name.nil?
	end 
	# set default clock back
	putz "Restoring clocks to default values"
	$state.default_clock.each do |p,v|
		$t.set_die_clock(p,v,$state.asic_package,$state.asic_die)
	end
	
	begin
		putz "Stopping client"
		$client.stop_service()
		if $os.os_type == "windows"
			$os.remove_auto_start()
		elsif $os.os_type == "linux"
			$os.remove_auto_start("vmin.rb")
		end
	rescue => e
		pute "Clean up error: #{e}\n #{e.backtrace.inspect}\n" 
	end
	stop_workload($state) unless $state.nil?
	$obj.delete()
	putz "Done cleanup"
end

#runs an xapp or tserver diag case
#returns true if tserver case passes, otherwise false
def run_workload(state)

	unless state.workload == nil || state.workload == ""
	
		sleep state.workload_delay
		
		putz "Running workload"
		if state.os_type == "windows"
			# binding.pry
			$app = Orclib::Application(state.workload, {})
			$t2 = Thread.new {results = $app.run()}
		elsif state.os_type == "linux"
			# binding.pry
			# ACP diag needs special running method
			diag = Orclib::Diagnostic(state.diag_folder)
			output = diag.run(state.workload)
			# binding.pry if state.phase_number == 2
			result = diag.parse_result
			if result == "pass" || result == "fail"
				return result
			else 
				summary = diag.summarize(result)
				puts "started diag test"
				pass = diag.passed?(summary)
				puts "done diag"
				putz "Diag pass: #{pass}"
				return pass
			end
		end
		
	end
end

def stop_workload(state)

	putz "stopping workload"
	if state.os_type == "windows"
		$app.stop unless (state.workload == nil || state.workload == "")
		$t2.join unless (state.workload == nil || state.workload == "")
	elsif state.os_type == "linux"
	end
	
end 

# keep decrementing code quickly until system fails
def run_phase1_vmin(state, settings = {})
	putz "Starting phase 1"
	state.phase_number = 1
	
	if state.voltage_module == "atitool"
		state.original_voltage = $t.get_package_voltage(state.voltage_rail_name,state.asic_package)	#save original state
		#begin with starting voltage
		state.current_voltage = state.starting_voltage
	elsif state.voltage_module == "smu"
		state.original_voltage[state.asic_package] = state.starting_voltage + 0.1
		#begin with starting voltage
		state.current_voltage = state.starting_voltage
	end

	
	#setting all packages and dies to default clock 
	state.default_clock.each do |i|
		$t.set_die_clock(i[0],i[1],"all","all")
	end
		
	
	#setting clock value to specific value if defined
	if state.adjust_clock.size > 0
		state.adjust_clock.each do |i|
			$t.set_die_clock(i[0],i[1],state.asic_package,state.asic_die)
		end
	end
	
	$obj.save(state)
	
	# start workload and voltage breakdown
	
	if state.os_type == "windows"
		run_workload(state)
		
		loop do
			putz "Setting #{state.voltage_rail_name} to #{state.current_voltage}"
			#perform voltage adjustment
			#debug
			if state.voltage_module == "atitool"
				$t.set_package_voltage(state.voltage_rail_name,state.current_voltage,state.asic_package)
				state.actual_voltage = $t.get_package_voltage(state.voltage_rail_name,state.asic_package)
				sleep(state.phase1_dur)
				state.last_passing_voltage = state.actual_voltage
				state.current_voltage -= state.voltage_step
			elsif state.voltage_module == "smu"
				$vlt.set_voltage_rail(state.voltage_rail_name, state.current_voltage)
				state.actual_voltage[state.asic_package] = state.current_voltage
				sleep(state.phase1_dur)
				state.last_passing_voltage = state.actual_voltage
				state.current_voltage -= state.voltage_step
			end
			$obj.save(state)
			
		end
	elsif state.os_type == "linux"
		# binding.pry
		# update timeout for diag test in Linux
		state.update_timeout = 0
		starting_time = Time.now
		result = run_workload(state)
		puts "result #{result}"
		if !result
			# state.task_done = run_phase2_vmin(state) 
			pute "Diag Test Fail, Moving on to next Test"
			return
		end
		ending_time = Time.now
		state.update_timeout = ending_time - starting_time
		puts "Finishing remeasure the timeout to #{state.update_timeout}"
		
		loop do
			# make sure the WD signal sent to server before running Diag
			$client.update_timeout(5 * state.update_timeout)
			result = run_workload(state)
			puts "result = #{result}"
			# assume for diag workload return pass or fail
			if !result
				state.task_done = run_phase2_vmin(state) 
				return
			end
			#voltage decrement 
			putz "Setting #{state.voltage_rail_name} to #{state.current_voltage}"
			
			if state.voltage_module == "atitool"
				$t.set_package_voltage(state.voltage_rail_name,state.current_voltage,state.asic_package)
				state.actual_voltage = $t.get_package_voltage(state.voltage_rail_name,state.asic_package)
				sleep(state.phase1_dur)
				state.last_passing_voltage = state.actual_voltage
				state.current_voltage -= state.voltage_step
			end
			
			$obj.save(state)
		end 
	end
	
	raise "Code should not get here"
	
end


#returns true if passes, false otherwise
def run_phase2_vmin(state, settings = {})
	putz "Starting phase 2"
	
	#if just switching from phase 1
		#binding.pry
		puts "state.current_voltage = #{$state.current_voltage} , will do "
		if state.phase_number == 1 
			
			state.current_voltage = state.last_passing_voltage[state.asic_package]
			state.results.push(state.last_passing_voltage[state.asic_package])
			state.results_header.push('vmin_phase1')
		else
			state.current_voltage += state.voltage_step		
		end
	puts "state.current_voltage = #{$state.current_voltage} , done "
	

	# binding.pry
	#overvoltage protections
	state.phase_number = 2
	
	#setting all packages and dies to default clock 
	state.default_clock.each do |i|
		$t.set_die_clock(i[0],i[1],"all","all")
	end
		
	
	#setting clock value to specific value if defined
	if state.adjust_clock.size > 0
		state.adjust_clock.each do |i|
			$t.set_die_clock(i[0],i[1],state.asic_package,state.asic_die)
		end
	end
	

	if (state.current_voltage > state.max_voltage)
		pute "Maximum voltage of #{state.max_voltage} reached - stopping test"
		putz "Restoring to #{state.original_voltage[state.asic_package]} V"
		if state.voltage_module == "atitool"
			$t.set_package_voltage(state.voltage_rail_name,state.original_voltage[state.asic_package],state.asic_package)	
		elsif state.voltage_module == "smu"
			$vlt.set_voltage_rail(state.voltage_rail_name, state.original_voltage[state.asic_package])
		end
		return false
	end
	
	# debug diag phase 2 load time
	sleep 10
	
	if state.os_type == "windows"
		putz "\nSetting #{state.voltage_rail_name} to #{state.current_voltage}"
		
		if state.voltage_module == "atitool"
			$t.set_package_voltage(state.voltage_rail_name,state.current_voltage,state.asic_package)
			state.actual_voltage = $t.get_package_voltage(state.voltage_rail_name,state.asic_package)
		elsif state.voltage_module == "smu"
			sleep 5
			$vlt.set_voltage_rail(state.voltage_rail_name,state.current_voltage)
			state.actual_voltage[state.asic_package] = state.current_voltage
		end
	

		
		$obj.save(state)
		
		
		run_workload(state)
		sleep(state.phase2_dur)
		stop_workload(state)
		
	elsif state.os_type == "linux"
	
		loop do
		
			# make sure the WD signal sent to server before running Diag
			p "Starting Diag Test Phase 2"
			$client.update_timeout(5 * state.update_timeout)
			result = []
			$state.diag_loops.times {result.push(run_workload(state).to_s)}
			#binding.pry
			putz "result = #{result}"
			# assume for diag workload return pass or fail
			break if (result.include?('pass') or result.include?('true'))
			
			# increment voltage by one step if fail
			state.current_voltage += state.voltage_step
			putz "\nSetting #{state.voltage_rail_name} to #{state.current_voltage}"
			$t.set_package_voltage(state.voltage_rail_name,state.current_voltage,state.asic_package)
			state.actual_voltage = $t.get_package_voltage(state.voltage_rail_name,state.asic_package)
		
			$obj.save(state)
	
		end
	end
			
	
	#restore to save voltage
	#debug
	# p state.voltage_rail_name
	# p state.original_voltage[state.asic_package]
	# p state.asic_package
	# binding.pry
	
	#restoring to default condition
	if state.voltage_module == "atitool"
		$t.set_package_voltage(state.voltage_rail_name,state.original_voltage[state.asic_package],state.asic_package)
	elsif state.voltage_module == "smu"
		$vlt.set_voltage_rail(state.voltage_rail_name, state.original_voltage[state.asic_package])
	end

	
	state.default_clock.each do |i|
		$t.set_die_clock(i[0],i[1],"all","all")
	end
	
	# binding.pry
	state.results.push(state.actual_voltage[state.asic_package])
	state.results_header.push('vmin_phase2')
	putz "Completed Phase2"
	
	#if it gets here it passed	
	return true	
	
end


begin
	putz "\nStarting Charz script v#{SCRIPT_VERSION}\n\n"

	$manstart = false

	ARGV.each { |i| $manstart = true if !!(i =~ /^--start$/)} 

	
	$xapp = nil
	$diag = nil
	
	$obj = Orclib::ObjectSave("vmin_data")
	
	$os = Orclib::OS()
	
		#if the script was manually started for the first time, create a new state
	if $manstart
		$state = CharzState.new()
		$state.current_row_number = 0
		# Identify  os type
		$state.os_type = $os.os_type
		ARGV.each  { |i|  $state.server_ip = $' if  !!(i =~ /^--server_ip=/i) }
		ARGV.each  { |i|  $state.wombat_ip = $' if  !!(i =~ /^--wombat_ip=/i) }
		ARGV.each  { |i|  $state.task_file_name = $' if  !!(i =~ /^--task_csv=/i) }
		ARGV.each  { |i|  $state.client_ip = $' if  !!(i =~ /^--client_ip=/i) }
		ARGV.each  { |i|  $state.diag_folder = $' if  !!(i =~ /^--diag_folder=/i) }
		$state.diag_folder = '/root/amddiag/apu/slt/diag/' if $state.diag_folder.nil? 
	else #continue with previous state
		$state = $obj.restore
	end

	
	
	putz "Wombat IP: #{$state.wombat_ip}, server ip: #{$state.server_ip}, client ip: #{$state.client_ip}"
	raise "Need valid Server and wombat ip" if $state.wombat_ip.nil? || $state.server_ip.nil?
	
	if $os.os_type == "windows"
		$os.make_auto_start()
	elsif $os.os_type == "linux"
		$os.make_auto_start("vmin.rb")
	end
	
	#start reset service that will restart the system if it hangs up
	$client = WatchDogClient.new($state.server_ip, $state.wombat_ip, $state.client_ip)
	# default timeout, update timeout for different diag time in Linux
	$client.start_service(60)

	
	#Perform one vmin task per loop by looking into the task csv
	loop do
		
		#get next task, unless working on a current task
		if  $state.phase_number == 0
			if File.exist?($state.task_file_name)
				putz "Loading #{$state.task_file_name}"
			else
				pute "CSV file does not exist: #{$state.task_file_name}"
				exit 1
			end
			list = CSV.read($state.task_file_name, headers: :true,converters: :numeric)
			
			#check for commented out rows (indicated by #)
			regex = /^#/	
			loop do
				if list.size <= $state.current_row_number #note that header is counted as well
					putz "Done all tasks"
					# @todo perform clean up
					exit 0
				end
				id_num = list[$state.current_row_number]["id"]
				if id_num.class == String && id_num.match(regex)
					$state.current_row_number += 1 
					putz "skipping row #{id_num}"
				else	
					break
				end
			end
			
			current_row = list[$state.current_row_number]
			putz "getting row #{$state.current_row_number} "
			
			$state.starting_voltage = current_row["starting_voltage"]
			$state.voltage_step = current_row["voltage_step"] unless current_row["voltage_step"].nil?
			$state.phase1_dur = current_row["phase1_duration"]
			$state.phase2_dur = current_row["phase2_duration"]
			#add diag_loops 
			#binding.pry
			if current_row.include?("diag_loops")
				#binding.pry
				$state.diag_loops = current_row["diag_loops"].to_i
			else 
				$state.diag_loops = 1
			end			
			#binding.pry
			$state.workload = current_row["workload"]
			
			$state.atitool_timeout = current_row["atitool_timeout"] unless current_row["atitool_timeout"].nil?

			$state.voltage_rail_name = current_row["voltage_rail_name"]	
			$state.results_header = []
			$state.results = []
			$state.id = current_row["id"]
			$state.workload_delay = current_row["workload_delay"] unless current_row["workload_delay"].nil?
			
			#define package and die
			$state.asic_package = current_row["asic_package"]
			$state.asic_die = current_row["asic_die"]
			
			#define voltage module
			$state.voltage_module = current_row["voltage_module"]
			
			#change xcaptan state if required in csv
			$state.xcaptan = true if current_row["xcaptan"] == true
			
			
			#reading clocks 
			regex = /clk_(.*)/
			current_row.headers.each do |i|
				if i.match(regex)
					#append to the clock hash
					$state.adjust_clock["#{i.match(regex)[1]}"] = current_row["#{i}"] unless current_row["#{i}"].nil?
				end
			end
			
			#default clocks 
			if $manstart
			regex = /clk_(.*)/
			default = Orclib::Atitool()
			default.timeout = 2
				current_row.headers.each do |i|
					if i.match(regex)
						clock_name = i.match(regex)[1]
						clock_value = default.get_die_clock("#{clock_name}")[0][0]["#{clock_name}"]
						$state.default_clock["#{i.match(regex)[1]}"] = clock_value
					end
				end
				p $state.default_clock
			end
		
		end
		
		putz "Done setup"
		putz "#{$state}"
		
		if $state.voltage_module == "atitool"
			$t = Orclib::Atitool()
			putz "Waiting for tool readiness"
			while $t.enumerate_devices.nil? || $t.enumerate_devices == []
				sleep 0.2 
				print '.'
			end
			$t.timeout = $state.atitool_timeout
		elsif $state.voltage_module == "smu"
			# for clock module using
			$t = Orclib::Atitool()
			$vlt = Orclib::Voltage_SMU()
		end

		
				
		#save the orignal condition of the system 
		if  $state.phase_number == 0  #Phase 1
			#binding.pry
			#phase 1 ... fast vmin decrease		
			run_phase1_vmin($state)
			
			
		else 	#phase 2
			#run phase 2 sequence
			$state.task_done = run_phase2_vmin($state)
			#increment until passing	
		end
	
		
		putr "#{$state}"
		
		#clock formatting showing adjust clock
		$state.adjust_clock.each do |i|
			$state.clock_name.push(i[0])
			$state.clock_list.push(i[1])
		end
		
		
		
		putcsv_header(['id','completed', 'duration','workload', 'dur1', 'dur2'] + ['vmin1', 'vmin2'] + ['package', 'die'] + $state.clock_name)
		putcsv([$state.id,$state.task_done, $state.duration(),$state.workload, $state.phase1_dur, $state.phase2_dur] + $state.results + [$state.asic_package, $state.asic_die] + $state.clock_list)
		
		
		$state.reset()
		$state.current_row_number += 1
	end
	
	putr "Done all tasks!"
rescue => e	
	pute e
	pute "Error: #{e}\n #{e.backtrace.inspect}\n"
	sleep 10
ensure
	clean_up()
	
end