<#
.Synopsis
   Repeatedly sends pings to computers, and draws an in-console view of the results, e.g.

   google.com | 18ms | .............x.....................x....
   8.8.8.8    | 15ms | ...................................x....
.DESCRIPTION
   Takes one or more ComputerNames as a parameter, or from the pipeline - names or IPs.
   Sets up a continuous loop of ping tests, and draws the last few ping results on screen.
   e.g. for pinging several things as you reboot them, and watching them come back online.

   Results key:
   . represents a ping reply
   x represents a timeout
   ? represents an exception or other failure during the ping
     (space) represents a complete failure to ping

   Pressing any key will break the loop and stop it running.

   It will use the entire width of the console, but you can 'shrink' it with -ResultCount


   NB. 'ping' requests are usually low priority for hosts to reply to, and often dropped
       if links are hitting bandwidth limits. A few blip timeouts when pinging over the
       internet is quite common, and you can't reliably use "one failure" to indicate a
       host is offline or has network problems.
.EXAMPLE
   Ping your local network firewall, Google out on the internet, and a remote machine
   at one of your other offices, so that when you reboot your firewall you can confirm
   it comes back online, the internet connection comes up, and the VPN comes up.

   PS D:\> pingm.ps1 192.168.0.1, google.com, 10.200.50.50
.EXAMPLE
   Use it as a rudimentary ping sweep to ping the first 10 IPs in 192.168.1.0/24:

   1..10 | foreach { "192.168.1.$_" } | .\pingm.ps1
.EXAMPLE
   Keep lots of results, it wraps around the screen:

   PS D:\> .\pingm.ps1 google.com, example.org -ResultCount 400
.INPUTS
   Inputs to this cmdlet:
   -ComputerName: one or more computer names or IP addresses, as a parameter or pipeline input.
   -ResultCount: how many ping results to store and draw for each host.
.OUTPUTS
   Output from this cmdlet: None, it's interactive only.
.NOTES
   General notes
#>
[CmdletBinding()]
Param
(
	[Parameter(Mandatory = $true,
		ValueFromPipeline = $true,
		ValueFromPipelineByPropertyName = $true,
		Position = 0)]
	[ValidateNotNullOrEmpty()]
	[string[]]$ComputerName,

	# Number of pings to show
	[Parameter(Position = 1)]
	[int]$ResultCount = 0
)

# Gather up pipeline input, if there was any
$PipelineItems = @($input)
if ($PipelineItems.Count) {
	$ComputerName = $PipelineItems
}

# Set some defaults
# Note: The '- 15' in ScreenWidth is allowance for the time column
[int] $ScreenWidth = ($Host.UI.RawUI.WindowSize.Width - 15)
[int] $longest = 0
# This dummy keeps the timeout from being a problem ... it fails quick
[string] $DummyIP = '127.0.0.1.2'

# Validate computernames
Write-Host "Validating/Looking up hosts..." -ForegroundColor Yellow

# Setup the data store for each computer, with a pinger, and a store for previous results
[array] $PingData = foreach ($Computer in $ComputerName) {
	if ($Computer.Length -gt $longest) { $longest = $Computer.Length }

	# Try to remove Name Lookups and display ping 'validity'
	write-host "  $($Computer) is " -NoNewline
	[string] $IPToPing = $Computer
	if (-not ($Computer -as [ipaddress])) {
		$IPToPing = (Resolve-DnsName $Computer -ErrorAction SilentlyContinue |
				Where-Object { $_.IP4Address -ne $null } | Select-Object -first 1).IP4Address
		if (-not ($IPToPing)) {
			$IPToPing = $DummyIP
			write-host "Invalid - Can't resolve" -ForegroundColor Red
		} else {
			Write-Host "Valid" -ForegroundColor Green -NoNewline
			Write-Host " - $($IPToPing)"
		}
	} else {
		Write-Host "Valid" -ForegroundColor Green
	}

	@{
		'Name'       = $Computer
		'Pinger'     = New-Object -TypeName System.Net.NetworkInformation.Ping
		'Results'    = New-Object -TypeName System.Collections.Queue($ResultCount)
		'LastResult' = @{}
		'IPToPing'   = $IPToPing
	}
}

if ($ResultCount -eq 0) {
	$ResultCount = ($ScreenWidth - $longest)
}

#let the user see the validated responses... but not for too long
start-sleep 1

# Redrawing the screen with Clear-Host causes it to flicker; each line is arranged
# to be the same length, so moving the cursor back to the top can overwrite them
# but this doesn't work in PS ISE, so this tries to detect that and use the nicer
# method if supported, falling back to Clear-Host
$UseClearHostWhenRedrawing = $false
try {
	[System.Console]::SetCursorPosition(0, 0)
} catch [System.IO.IOException] {
	$UseClearHostWhenRedrawing = $true
}

# Clear host anyway, for the first run.
Clear-Host
# Write the header
Write-Host " " -NoNewline
Write-Host "Host".PadLeft($longest / 2).PadRight($longest) -NoNewline -ForegroundColor White -BackgroundColor DarkGray
Write-Host " |    Time |"  -NoNewline  -ForegroundColor White -BackgroundColor DarkGray
Write-Host " Responses" -NoNewline -ForegroundColor White -BackgroundColor DarkGray
write-host $(" " * ($ResultCount - "Responses".Length)) -ForegroundColor White -BackgroundColor DarkGray

# Allows Control-C to abort via the 'Any key will quit' but not exit as error
[console]::TreatControlCAsInput = $true

# Run the main code loop - ping forever
while ($true) {
	if ([console]::KeyAvailable) {
		# Any key will quit
		$x = [System.Console]::ReadKey($true)

		switch ($x.key) {
			Default { Write-host "`nExiting..." -ForegroundColor Green; exit }
		}
	} else {

		# Send pings to each computer in the background
		[array]$PingTasks = foreach ($Item in $PingData) {
			# Need to add a try/catch around this, but major rework reqiured...
			# Basically, no network, errors...
			$Item.Pinger.SendPingAsync($Item.IPToPing)
			# NB. it is possible to set a timeout in ms here,
			#     but it doesn't work reliably, reporting false
			#     TimedOut replies even when replies do come back,
			#     so I removed it and leave the default.
		}

		# Wait for all the results
		try {
			[Threading.Tasks.Task]::WaitAll($PingTasks)
		} catch [AggregateException] {
			# This happens e.g. if there's a failed DNS lookup in one of the tasks
			# Just going to let it happen, silence it, check the results later,
			# and display failed tasks differently.
		}

		# Update PingData store with results for each computer
		0..($PingTasks.Count - 1) | ForEach-Object {
			$Task = $PingTasks[$_]
			$ComputerData = $PingData[$_]

			if ($Task.Status -ne 'RanToCompletion') {
				$ComputerData.Results.Enqueue('')
			} else {
				$ComputerData.LastResult = $Task.Result

				# see https://msdn.microsoft.com/en-us/library/system.net.networkinformation.ipstatus(v=vs.110).aspx
				switch ($Task.Result.Status) {
					'Success' { $ComputerData.Results.Enqueue('.') }
					'TimedOut' { $ComputerData.Results.Enqueue('x') }
					Default { $ComputerData.Results.Enqueue('?') }
				}
			}
			# Stop results store growing forever, remove old entries if they get too big.
			if ($ComputerData.Results.Count -gt $ResultCount) {
				$null = $ComputerData.Results.DeQueue()
			}
		}

		# ReDraw screen
		if ($UseClearHostWhenRedrawing) {
			Clear-Host
		} else {
			$CursorPosition = $Host.UI.RawUI.CursorPosition
			$CursorPosition.X = 0
			$CursorPosition.Y = 1
			$Host.UI.RawUI.CursorPosition = $CursorPosition
		}

		# Draw a line of results for each computer, with color indicating ping reply or not
		foreach ($Item in $PingData) {
			write-host " " -NoNewline
			# # Draw computer name with colour
			# if ($Item.LastResult.Status -eq 'Success') {
			# 	Write-Host (($Item.Name).PadRight($longest)) -BackgroundColor DarkGreen -NoNewline
			# } else {
			# 	Write-Host (($Item.Name).PadRight($longest)) -BackgroundColor DarkRed -NoNewline
			# }
			# write-host '  ' -NoNewline

			# Handle ping to make it fixed width and get colors
			[string] $PingColor = 'Green'
			if ($Item.LastResult.Status -eq 'Success') {
				if (1000 -le $Item.LastResult.RoundTripTime) {
					$PingText = ' 999+ms '
					$PingColor = 'Red'
				} else {
					$PingText = ' {0}ms ' -f $Item.LastResult.RoundTripTime.ToString().PadLeft(4, ' ')
					if ($Item.LastResult.RoundTripTime -gt 250) { $PingColor = 'yellow' }
					elseif ($Item.LastResult.RoundTripTime -gt 700) { $PingColor = 'Red' }
				}
			} else {
				$PingText = '  ----- '
				$PingColor = 'Red'
			}

			# Draw computer name with colour
			Write-Host (($Item.Name).PadRight($longest + 1)) -BackgroundColor ("Dark$($PingColor)") -NoNewline
			write-host '| ' -NoNewline

			# Draw ping text and computer name
			Write-Host $PingText -NoNewline -ForegroundColor $PingColor

			# Draw the results array
			write-host '| ' -NoNewline

			## This is WAY too slow. Revisit some day...? Prolly not
			# [char[]] $ResultChars = ([regex]::Matches(($Item.Results -join ''), '.', 'RightToLeft').Value)
			# foreach ($c in $ResultChars) {
			# 	switch ($c) {
			# 		'.' { $ResultColor = 'green' }
			# 		'x' { $ResultColor = 'red' }
			# 		'?' { $ResultColor = 'yellow' }
			# 		Default { $ResultColor = 'gray' }
			# 	}
			# 	write-host $c -ForegroundColor $ResultColor -NoNewline
			# }
			# write-host ""

			$tempString = ([regex]::Matches(($Item.Results -join ''), '.', 'RightToLeft').Value -join '')
			Write-Host $tempString.Substring(0, ($tempstring.Length - 1)) -NoNewline -ForegroundColor DarkGray
			Write-Host $tempString.Substring(($tempstring.Length - 1)) -ForegroundColor $PingColor
		}

		Write-Host " " -NoNewline
		write-host $(" " * ($ResultCount + $longest + " |  -----  | ".Length)) -ForegroundColor White -BackgroundColor DarkGray
		Write-Host ""
		Write-Host ' ________Legend________'
		Write-Host '   [.]   reply'
		Write-Host '   [x]   timeout'
		Write-Host '   [?]   failure'
		Write-Host '   [ ]   abject failure'

		# Delay restarting the ping loop
		# Try to be 1 second wait, minus the time spent waiting for the slowest ping reply.
		## maybe [math]::abs( -10 )  ##  yields  10

		$Delay = 1000 - ($PingData.lastresult.roundtriptime | Sort-Object | Select-Object -Last 1)
		Start-Sleep -MilliSeconds $Delay
	}
}
