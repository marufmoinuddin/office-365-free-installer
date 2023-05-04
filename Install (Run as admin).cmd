echo off
title Office 2013-2019, 365 installer by TiTAN1UM v5.0
:begin
	cls
	@echo off
	goto check_Permissions

	:check_Permissions
		echo ============================================================================
		

		net session >nul 2>&1
		if %errorLevel% == 0 (
			echo Office 2013-2019, 365 installer by TiTAN1UM v5.0
			
		) else (
			echo Failure: Current permissions inadequate. Please Run as Administrator.
			echo ============================================================================
			pause >nul
		)
	echo ============================================================================
	echo                                 -+yddy:..``                                           
	echo                             `:ohddddmmh+++///:.                                       
	echo                          -+shhhddddddhs++++++++-                                      
	echo                        .shhhhhhhyo/-. `oooooooo:                                      
	echo                         :yyyhhy-`      .oooooooo:                                      
	echo                        :yyyyy/        .osssssss:                                      
	echo                        :yyyyy/        .ssssssss/                                      
	echo                        -ssssy/        .ssssssss/                                      
	echo                        -sssss/        .ssssssss/                                      
	echo                        -oosss:        .ssssssss/                                      
	echo                        -ooooo.        .ssssssss/                                      
	echo                        `//-.`         -ssssssss/                                      
	echo                            `osssssyyyyhssssssss/                                      
	echo                             .:osssyyyyhsssssso/`                                      
	echo                                `-+syyyo+/:-.``                                        
	echo                                   `````                                               


	echo ============================================================================
	echo Please select an option (Also please read the README file):
	echo ============================================================================
	echo -
	echo 1) Install Office 365
	echo 2) Install / Uninstall / Actiate Office 2013-2019
	echo 3) Exit
	echo -
	set /p op=Type option: 
	if "%op%"=="1" goto op1
	if "%op%"=="2" goto op2
	if "%op%"=="3" goto exit

	echo Please Pick an option:
	goto begin


	:op1
		echo -
		echo Installing Office 365
		echo Please select an option:
		echo ============================================================================
		echo -
		echo 1) Full
		echo 2) Minimal
		echo -
		set /p op=Type option: 
		if "%op%"=="1" goto ip1
		if "%op%"=="2" goto ip2
		echo Please Pick an option:
		goto op1

		:ip1
			echo -
			echo Installing Office 365 (Full)
			cd /d %~dp0
			bin\setup.exe /configure bin\Configuration2.xml
			echo Installation finished.

			goto end
		:ip2
			echo -
			echo Installing Office 365 (Minimal)
			cd /d %~dp0
			bin\setup.exe /configure bin\Configuration.xml
			echo Installation finished.
			

			goto end

	:op2
		echo -
		echo Opening Office 2013-2019 Installer
		cd /d %~dp0
		bin\OInstall.exe
		goto end

		
	:end
		echo -
		choice /n /c YN /m "Return to previous options [Y,N]?"
		IF ERRORLEVEL 2 exit
		goto begin

	:exit
		@exit