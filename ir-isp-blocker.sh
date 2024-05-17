#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    clear
    echo "You should run this script with root!"
    echo "Use sudo -i to change user to root"
    exit 1
fi

function main_menu {
    clear
    
    echo "  _____   _____             _____    _____   _____             ____    _                  _                  
 |_   _| |  __ \           |_   _|  / ____| |  __ \           |  _ \  | |                | |                 
   | |   | |__) |  ______    | |   | (___   | |__) |  ______  | |_) | | |   ___     ___  | | __   ___   _ __ 
   | |   |  _  /  |______|   | |    \___ \  |  ___/  |______| |  _ <  | |  / _ \   / __| | |/ /  / _ \ | '__|
  _| |_  | | \ \            _| |_   ____) | | |               | |_) | | | | (_) | | (__  |   <  |  __/ | |   
 |_____| |_|  \_\          |_____| |_____/  |_|               |____/  |_|  \___/   \___| |_|\_\  \___| |_|   
https://github.com/Kiya6955/IR-ISP-Blocker"
    echo "Which ISP do you want block/unblock?"
    echo "--------------------------------------"
    echo "1-MCI(Hamrah Aval)"
    echo "2-MTN(Irancell)"
    echo "3-TCI(Mokhaberat)"
    echo "4-Exit"
    read -p "Enter your choice: " isp
    case $isp in
    1) isp="MCI" blocking_menu ;;
    2) isp="MTN" blocking_menu ;;
    3) isp="TCI" blocking_menu ;;
    4) echo "Exiting..."; exit 0 ;;
    *) echo "Invalid option"; main_menu ;;
    esac
}

function blocking_menu {
    clear
    echo "---------- $isp Menu ----------"
    echo "1-Block $isp"
    echo "2-UnBlock All"
    echo "3-Back to Main Menu"
    read -p "Enter your choice: " choice
    case $choice in
        1) blocker ;;
        2) unblocker ;;
        3) main_menu ;;
        *) echo "Invalid option press enter"; blocking_menu ;;
    esac
}

function blocker {

    clear
    # Install iptables
    if ! command -v iptables &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y iptables
    fi
    if ! dpkg -s iptables-persistent &> /dev/null; then
        sudo apt-get install -y iptables-persistent
    fi

    # Create chain
    if ! iptables -L isp-blocker -n >/dev/null 2>&1; then
    iptables -N isp-blocker
    fi

    if ! iptables -C INPUT -j isp-blocker &> /dev/null; then
        iptables -I INPUT 1 -j isp-blocker
    fi

    clear

    # Ask User
    read -p "Are you sure about blocking $isp? [Y/N] : " confirm
    
    if [[ $confirm == [Yy]* ]]; then
        clear

        # Get the IP list from Github
        if [ "$isp" == "MCI" ]; then
        IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/mci-ips.ipv4')
        if [ $? -ne 0 ]; then
        echo "Failed to fetch the MTN IP list. Please contact with @Kiya6955"
        read -p "Press enter to return to Menu" dummy
        blocking_menu
        fi
        elif [ "$isp" == "TCI" ]; then
        IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/tci-ips.ipv4')
        if [ $? -ne 0 ]; then
        echo "Failed to fetch the MTN IP list. Please contact with @Kiya6955"
        read -p "Press enter to return to Menu" dummy
        blocking_menu
        fi
        else
        IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/mtn-ips.ipv4')
        if [ $? -ne 0 ]; then
        echo "Failed to fetch the MTN IP list. Please contact with @Kiya6955"
        read -p "Press enter to return to Menu" dummy
        blocking_menu
        fi
        sudo iptables -A INPUT -s $IP -p $protocol --match multiport --dport $ports -j DROP
        fi
        
        clear

        echo "Choose an option:"
        echo "1-Block specific ports for $isp"
        echo "2-Block all ports for $isp"
        echo "3-Back to Main Menu"
        read -p "Enter your choice: " choice

        clear

        # Save ports in array
        if [[ $choice == 1 ]]; then
        read -p "Enter the ports you want block for $isp(enter single like 443 or separated by comma like 443,8443): " ports
        IFS=' ' read -r -a portArray <<< "$ports"
        fi

    case $choice in
        1)
            clear

            # Ask user to block TCP or UDP or Both
            echo "Choose Protocol that you want to block for $isp"
            echo "1-TCP & UDP"
            echo "2-TCP"
            echo "3-UDP"
            read -p "Enter your choice: " protocol

            case $protocol in
            1) protocol="all" ;;
            2) protocol="tcp" ;;
            3) protocol="udp" ;;
            *) echo "Invalid option"; blocker ;;
            esac
            
            clear

            read -p "Do you want to delete the previous rules? [Y/N] : " confirm
            if [[ $confirm == [Yy]* ]]; then
            sudo iptables -F isp-blocker
            echo "Previous rules deleted successfully"
            sleep 2s
            fi

            clear

            echo "Blocking [$ports] for $isp started please Wait..."

            for ports in "${portArray[@]}"
            do
            for IP in $IP_LIST; do
                if [ "$protocol" == "all" ]; then
                    # Add Rules for both TCP and UDP
                    sudo iptables -A isp-blocker -s $IP -p tcp --match multiport --dport $ports -j DROP
                    sudo iptables -A isp-blocker -s $IP -p udp --match multiport --dport $ports -j DROP
                else
                    # Add Rules for either TCP or UDP
                    sudo iptables -A isp-blocker -s $IP -p $protocol --match multiport --dport $ports -j DROP
                fi
            done
            done

            # Save rules
            sudo iptables-save > /etc/iptables/rules.v4

            clear

            if [ "$protocol" == "all" ]; then
            echo "TCP & UDP [$ports] successfully blocked for $isp."
            else
            echo "$protocol [$ports] successfully blocked for $isp."
            fi
            ;;
        2)
            clear

            read -p "Do you want to delete the previous rules? [Y/N] : " confirm
            if [[ $confirm == [Yy]* ]]; then
            sudo iptables -F isp-blocker
            echo "Previous rules deleted successfully"
            sleep 2s
            fi

            clear
            
            # Open SSH Port
            read -p "Enter the SSH port you want to open (default is 22): " SSH_PORT
            SSH_PORT=${SSH_PORT:-22}

            sudo iptables -A isp-blocker -p tcp --dport $SSH_PORT -j ACCEPT

            clear
            
            echo "Blocking all ports for $isp started please Wait..."
            # Add new rules
            for IP in $IP_LIST; do
                sudo iptables -A isp-blocker -s $IP -j DROP
            done
            
            # Save rules
            sudo iptables-save > /etc/iptables/rules.v4

            
            clear

            echo "$isp successfully blocked for all ports."
            echo "Port $SSH_PORT has been opened for SSH."
            ;;
        *) echo "Invalid option"; blocking_menu ;;
    esac
        read -p "Press enter to return to Menu" dummy
        blocking_menu
    else
        echo "Cancelled."
        read -p "Press enter to return to Menu" dummy
        blocking_menu
    fi
}

function unblocker {
    clear
    sudo iptables -F isp-blocker
    sudo iptables-save > /etc/iptables/rules.v4
    clear
    echo "All ISPs UnBlocked successfully!"
    read -p "Press enter to return to Menu" dummy
    blocking_menu
}
# Start the script
main_menu
