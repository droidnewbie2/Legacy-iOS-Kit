#!/bin/bash
trap "Clean" EXIT
trap "Clean; exit 1" INT TERM

cd "$(dirname $0)"
. ./resources/blobs.sh
. ./resources/depends.sh
. ./resources/device.sh
. ./resources/downgrade.sh
. ./resources/ipsw.sh

if [[ $1 != "NoColor" && $2 != "NoColor" ]]; then
    TERM=xterm-256color
    Color_R=$(tput setaf 9)
    Color_G=$(tput setaf 10)
    Color_B=$(tput setaf 12)
    Color_Y=$(tput setaf 11)
    Color_N=$(tput sgr0)
fi

Clean() {
    rm -rf iP*/ shsh/ tmp/ *.im4p *.bbfw ${UniqueChipID}_${ProductType}_*.shsh2 \
    ${UniqueChipID}_${ProductType}_${HWModel}ap_*.shsh BuildManifest.plist
    kill $iproxyPID 2>/dev/null
    if [[ $ServerRunning == 1 ]]; then
        Log "Stopping local server..."
        if [[ $platform == "macos" ]]; then
            ps aux | awk '/python/ {print "kill -9 "$2" 2>/dev/null"}' | bash
        elif [[ $platform == "linux" ]]; then
            Echo "* Enter root password of your PC when prompted"
            ps aux | awk '/python/ {print "sudo kill -9 "$2" 2>/dev/null"}' | bash
        fi
    fi
}

Echo() {
    echo "${Color_B}$1 ${Color_N}"
}

Error() {
    echo -e "\n${Color_R}[Error] $1 ${Color_N}"
    [[ ! -z $2 ]] && echo "${Color_R}* $2 ${Color_N}"
    echo
    if [[ $platform == "win" ]]; then
        Input "Press Enter/Return to exit."
        read -s
    fi
    exit 1
}

Input() {
    echo "${Color_Y}[Input] $1 ${Color_N}"
}

Log() {
    echo "${Color_G}[Log] $1 ${Color_N}"
}

Main() {
    local SkipMainMenu
    
    clear
    Echo "******* iOS-OTA-Downgrader *******"
    Echo "   Downgrader script by LukeZGD   "
    echo
    
    if [[ $EUID == 0 ]]; then
        Error "Running the script as root is not allowed."
    fi

    if [[ ! -d ./resources ]]; then
        Error "resources folder cannot be found. Replace resources folder and try again." \
        "If resources folder is present try removing spaces from path/folder name"
    fi
    
    SetToolPaths
    if [[ $? != 0 ]]; then
        Error "Setting tool paths failed. Your copy of iOS-OTA-Downgrader seems to be incomplete."
    fi
    
    if [[ ! $platform ]]; then
        Error "Platform unknown/not supported."
    fi
    
    chmod +x ./resources/*.sh ./resources/tools/*
    if [[ $? != 0 ]]; then
        Log "Warning - An error occurred in chmod. This might cause problems..."
    fi
    
    Log "Checking Internet connection..."
    if [[ ! $(ping -c1 1.1.1.1 2>/dev/null) ]]; then
        Error "Please check your Internet connection before proceeding."
    fi
    
    if [[ $platform == "macos" && $(uname -m) != "x86_64" ]]; then
        Log "Apple Silicon Mac detected. Support may be limited, proceed at your own risk."
    elif [[ $(uname -m) != "x86_64" ]]; then
        Error "Only 64-bit (x86_64) distributions are supported."
    fi
    
    if [[ $1 == "Install" || ! $bspatch || ! $ideviceinfo || ! $irecoverychk || ! $python ||
          ! -d ./resources/libimobiledevice_$platform ]]; then
        Clean
        InstallDepends
    fi
    
    if [[ $platform != "win" ]]; then
        SaveExternal LukeZGD ipwndfu
    fi

    GetDeviceValues
    
    Clean
    mkdir tmp
    
    [[ ! -z $1 ]] && SkipMainMenu=1

    if [[ $SkipMainMenu == 1 && $1 != "NoColor" ]]; then
        Mode="$1"
    else
        Selection=("Downgrade device" "Save OTA blobs")
        if [[ $DeviceProc != 7 && $DeviceState == "Normal" ]]; then
            Selection+=("Just put device in kDFU mode")
        fi
        Selection+=("(Re-)Install Dependencies" "(Any other key to exit)")
        Echo "*** Main Menu ***"
        Input "Select an option:"
        select opt in "${Selection[@]}"; do
        case $opt in
            "Downgrade device" ) Mode="Downgrade"; break;;
            "Save OTA blobs" ) Mode="SaveOTABlobs"; break;;
            "Just put device in kDFU mode" ) Mode="kDFU"; break;;
            "(Re-)Install Dependencies" ) InstallDepends;;
            * ) exit 0;;
        esac
        done
    fi

    SelectVersion

    if [[ $Mode != "Downgrade" ]]; then
        $Mode
        if [[ $platform == "win" ]]; then
            Input "Press Enter/Return to exit."
            read -s
        fi
        exit 0
    fi

    if [[ $DeviceProc == 7 && $platform == "win" ]]; then
        local Message="If you want to restore your A7 device on Windows, put the device in pwnDFU mode."
        if [[ $DeviceState == "Normal" ]]; then
            Error "$Message"
        elif [[ $DeviceState == "Recovery" ]]; then
            Log "A7 device detected in recovery mode."
            Log "$Message"
            RecoveryExit
        elif [[ $DeviceState == "DFU" ]]; then
            Log "A7 device detected in DFU mode."
            Echo "* Make sure that your device is already in pwnDFU mode with signature checks disabled."
            Echo "* If your device is not in pwnDFU mode, the restore will not proceed!"
            Echo "* Entering pwnDFU mode is not supported on Windows. You need to use a Mac/Linux machine or another iOS device to do so."
            Input "Press Enter/Return to continue (or press Ctrl+C to cancel)"
            read -s
        fi

    elif [[ $DeviceProc == 7 ]]; then
        if [[ $DeviceState == "Normal" ]]; then
            Echo "* The device needs to be in recovery/DFU mode before proceeding."
            read -p "$(Input 'Send device to recovery mode? (y/N):')" Selection
            [[ $Selection == 'Y' || $Selection == 'y' ]] && Recovery || exit
        elif [[ $DeviceState == "Recovery" ]]; then
            Recovery
        elif [[ $DeviceState == "DFU" ]]; then
            CheckM8
        fi
    
    elif [[ $DeviceState == "DFU" ]]; then
        Mode="Downgrade"
        Echo "* Advanced Options Menu"
        Input "This device is in:"
        Selection=("kDFU mode")
        if [[ $platform != "win" ]]; then
            [[ $DeviceProc == 5 ]] && Selection+=("pwnDFU mode (A5)")
            [[ $DeviceProc == 6 ]] && Selection+=("DFU mode (A6)")
        fi
        Selection+=("Any other key to exit")
        select opt in "${Selection[@]}"; do
        case $opt in
            "kDFU mode" ) break;;
            "DFU mode (A6)" ) CheckM8; break;;
            "pwnDFU mode (A5)" )
                Echo "* Make sure that your device is in pwnDFU mode using an Arduino+USB Host Shield!";
                Echo "* This option will not work if your device is not in pwnDFU mode.";
                Input "Press Enter/Return to continue (or press Ctrl+C to cancel)";
                read -s;
                kDFU iBSS; break;;
            * ) exit 0;;
        esac
        done
        Log "Downgrading $ProductType in kDFU/pwnDFU mode..."
    
    elif [[ $DeviceState == "Recovery" ]]; then
        if [[ $DeviceProc == 6 && $platform != "win" ]]; then
            Recovery
        else
            Log "32-bit A${DeviceProc} device detected in recovery mode."
            Echo "* Please put the device in normal mode and jailbroken before proceeding."
            Echo "* For usage of advanced DFU options, put the device in kDFU or pwnDFU mode"
            RecoveryExit
        fi
        Log "Downgrading $ProductType in pwnDFU mode..."
    fi
    
    Downgrade

    if [[ $platform == "win" ]]; then
        Input "Press Enter/Return to exit."
        read -s
    fi
    exit 0
}

SelectVersion() {
    if [[ $Mode == "kDFU" ]]; then
        return
    elif [[ $ProductType == "iPad4"* || $ProductType == "iPhone6"* ]]; then
        OSVer="10.3.3"
        BuildVer="14G60"
        return
    fi
    
    if [[ $ProductType == "iPhone5,3" || $ProductType == "iPhone5,4" ]]; then
        Selection=()
    else
        Selection=("iOS 8.4.1")
    fi
    
    if [[ $ProductType == "iPad2,1" || $ProductType == "iPad2,2" ||
          $ProductType == "iPad2,3" || $ProductType == "iPhone4,1" ]]; then
        Selection+=("iOS 6.1.3")
    fi
    
    [[ $Mode == "Downgrade" && $platform != "win" ]] && Selection+=("Other (use SHSH blobs)")
    Selection+=("(Any other key to exit)")
    
    echo
    Input "Select iOS version:"
    select opt in "${Selection[@]}"; do
    case $opt in
        "iOS 8.4.1" ) OSVer="8.4.1"; BuildVer="12H321"; break;;
        "iOS 6.1.3" ) OSVer="6.1.3"; BuildVer="10B329"; break;;
        "Other (use SHSH blobs)" ) OSVer="Other"; break;;
        *) exit 0;;
    esac
    done
}

Main $1
