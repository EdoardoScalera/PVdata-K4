run logger 
powershell -ExecutionPolicy Bypass -File full_path.\shelly_logger.ps1

run demand control (only once add   -RunOnce)
powershell.exe -ExecutionPolicy Bypass -File .\shelly_load_control_scenarios.ps1 -ConfigPath .\shelly_load_control_scenarios.json 




Start the controller like this:
.\shelly_load_control_scenarios.ps1 `
  -ConfigPath .\shelly_load_control_scenarios.json `
  -Scenario whole_house

Request a scenario switch while it is running like this:
.\shelly_load_control_scenarios.ps1 -SetScenarioAllOn
.\shelly_load_control_scenarios.ps1 -SetScenarioWholeHouse
.\shelly_load_control_scenarios.ps1 -SetScenarioConstant1kW
.\shelly_load_control_scenarios.ps1 -SetScenarioAdaptive

Inspect pending request or current status:
.\shelly_load_control_scenarios.ps1 -ShowScenario
.\shelly_load_control_scenarios.ps1 -ShowStatus
.\shelly_load_control_scenarios.ps1 -ClearScenarioRequest




Get-ExecutionPolicy -
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
Get-Item ".\shelly_load_control_scenarios.ps1" -Stream Zone.Identifier -ErrorAction SilentlyContinue
Unblock-File -Path ".\shelly_load_control_scenarios.ps1"
