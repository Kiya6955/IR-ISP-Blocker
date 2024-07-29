#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    clear
    echo "You should run this script with root!"
    echo "Use sudo -i to change user to root"
    exit 1
fi

function main_menu {
    clear
    echo "----------- IR-ISP-Blocker -----------"
    echo "https://github.com/Kiya6955/IR-ISP-Blocker"
    echo "--------------------------------------"
    echo "Which ISP do you want block/unblock?"
    echo "--------------------------------------"
    echo "1-Hamrah Aval"
    echo "2-Irancell"
    echo "3-Mokhaberat"
    echo "4-Rightel"
    echo "5-Shatel"
    echo "6-AsiaTech"
    echo "7-Pishgaman"
    echo "8-MobinNet"
    echo "9-ParsOnline"
    echo "10-Exit"
    read -p "Enter your choice: " isp
    case $isp in
    1) isp="MCI" blocking_menu ;;
    2) isp="MTN" blocking_menu ;;
    3) isp="TCI" blocking_menu ;;
    4) isp="RTL" blocking_menu ;;
    5) isp="SHT" blocking_menu ;;
    6) isp="ASI" blocking_menu ;;
    7) isp="PIS" blocking_menu ;;
    8) isp="MOB" blocking_menu ;;
    9) isp="PAR" blocking_menu ;;
    10) echo "Exiting..."; exit 0 ;;
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
    if ! command -v iptables &> /dev/null; then
        apt-get update
        apt-get install -y iptables
    fi
    if ! dpkg -s iptables-persistent &> /dev/null; then
        apt-get update
        apt-get install -y iptables-persistent
    fi

    if ! iptables -L isp-blocker -n >/dev/null 2>&1; then
        iptables -N isp-blocker
    fi

    if ! iptables -C INPUT -j isp-blocker &> /dev/null; then
        iptables -I INPUT -j isp-blocker
    fi

    clear
    read -p "Are you sure about blocking $isp? [Y/N] : " confirm
    
    if [[ $confirm == [Yy]* ]]; then
        clear
        case $isp in
        "MCI")
            IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/mci-ips.ipv4')
            ;;
        "MTN")
            IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/mtn-ips.ipv4')
            ;;
        "TCI")
            IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/tci-ips.ipv4')
            ;;
        "RTL")
            IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/rightel-ips.ipv4')
            ;;
        "SHT")
            IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/shatel-ips.ipv4')
            ;;
        "ASI")
            IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/asiatech-ips.ipv4')
            ;;
        "PIS")
            IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/pishgaman-ips.ipv4')
            ;;
        "MOB")
            IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/mobinnet-ips.ipv4')
            ;;
        "PAR")
            IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/IR-ISP-Blocker/main/parsan-ips.ipv4')
            ;;
        esac

        if [ $? -ne 0 ]; then
            echo "Failed to fetch the IP list. Please contact @Kiya6955"
            read -p "Press enter to return to Menu" dummy
            blocking_menu
        fi
        
        clear
        echo "Choose an option:"
        echo "1-Block specific ports for $isp"
        echo "2-Block all ports for $isp"
        echo "3-Back to Main Menu"
        read -p "Enter your choice: " choice

        clear
        read -p "Enter IP addresses you want whitelist for $isp (separate with comma like 1.1.1.1,8.8.8.8 or leave empty for none): " whitelist_ips
        IFS=',' read -r -a whitelistIPArray <<< "$whitelist_ips"
        
        clear
        if [[ $choice == 1 ]]; then
            read -p "Enter the ports you want block for $isp (enter single like 443 or separated by comma like 443,8443): " ports
            IFS=',' read -r -a portArray <<< "$ports"
        fi

        case $choice in
            1)
                clear
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
                    iptables -F isp-blocker
                    echo "Previous rules deleted successfully"
                    sleep 2s
                fi

                clear
                echo "Blocking [$ports] for $isp started please wait..."

                for ip in "${whitelistIPArray[@]}"; do
                    iptables -I isp-blocker -s $ip -j ACCEPT
                done

                for port in "${portArray[@]}"
                do
                    for IP in $IP_LIST; do
                        if [ "$protocol" == "all" ]; then
                            iptables -A isp-blocker -s $IP -p tcp --dport $port -j DROP
                            iptables -A isp-blocker -s $IP -p udp --dport $port -j DROP
                        else
                            iptables -A isp-blocker -s $IP -p $protocol --dport $port -j DROP
                        fi
                    done
                done

                iptables-save > /etc/iptables/rules.v4

                clear
                if [ "$protocol" == "all" ]; then
                    echo "TCP & UDP [$ports] successfully blocked for $isp."
                else
                    echo "$protocol [$ports] successfully blocked for $isp."
                fi
                ;;
            2)
                clear
                read -p "Enter ports you want whitelist for $isp (separate with comma like 443,8443 or leave empty for none): " whitelist_ports
                IFS=',' read -r -a whitelistPortArray <<< "$whitelist_ports"

                clear
                read -p "Enter the SSH port you want open for $isp (default is 22): " SSH_PORT
                SSH_PORT=${SSH_PORT:-22}

                clear
                read -p "Do you want to delete the previous rules? [Y/N] : " confirm
                if [[ $confirm == [Yy]* ]]; then
                    iptables -F isp-blocker
                    echo "Previous rules deleted successfully"
                    sleep 2s
                fi

                clear
                echo "Blocking all ports for $isp started please wait..."

                for ip in "${whitelistIPArray[@]}"; do
                    iptables -I isp-blocker -s $ip -j ACCEPT
                done

                for port in "${whitelistPortArray[@]}"; do
                    iptables -I isp-blocker -p tcp --dport $port -j ACCEPT
                    iptables -I isp-blocker -p udp --dport $port -j ACCEPT
                done

                iptables -I isp-blocker -p tcp --dport $SSH_PORT -j ACCEPT

                for IP in $IP_LIST; do
                    iptables -A isp-blocker -s $IP -j DROP
                done
                
                iptables-save > /etc/iptables/rules.v4

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
    iptables -F isp-blocker
    iptables-save > /etc/iptables/rules.v4
    clear
    echo "All ISPs UnBlocked successfully!"
    read -p "Press enter to return to Menu" dummy
    blocking_menu
}

main_menu
