#!/bin/bash

function main_menu {
    clear
    echo "---------- Main Menu ----------"
    echo "Which ISP do you want block/unblock? : "
    echo "1-MCI(Hamrah Aval)"
    echo "2-MTN(Irancell)"
    echo "3-No One.Exit"
    read -p "Enter your choice: " isp
    case $isp in
    1) isp="MCI" blocking_menu ;;
    2) isp="MTN" blocking_menu ;;
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
    sudo apt-get update
    sudo apt-get install -y iptables
    clear

    # Ask User
    read -p "Are you sure about blocking $isp? [Y/N] : " confirm
    
    if [[ $confirm == [Yy]* ]]; then
        clear

        # Get the IP list from Github
        if [ "$isp" == "MCI" ]; then
        IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/ISP-Blocker/main/mci-ips.txt')
        if [ $? -ne 0 ]; then
        echo "Failed to fetch the MTN IP list. Please contact with @Kiya6955"
        read -p "Press enter to return to Menu" dummy
        blocking_menu
        fi
        else
        IP_LIST=$(curl -s 'https://raw.githubusercontent.com/Kiya6955/ISP-Blocker/main/mtn-ips.txt')
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

            # Delete previous rules
            sudo iptables -F

            for ports in "${portArray[@]}"
            do
            for IP in $IP_LIST; do
                if [ "$protocol" == "all" ]; then
                    # Add Rules for both TCP and UDP
                    sudo iptables -A INPUT -s $IP -p tcp --match multiport --dport $ports -j DROP
                    sudo iptables -A INPUT -s $IP -p udp --match multiport --dport $ports -j DROP
                else
                    # Add Rules for either TCP or UDP
                    sudo iptables -A INPUT -s $IP -p $protocol --match multiport --dport $ports -j DROP
                fi
            done
            done

            # ّFind and open SSH port
            SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
            if [ -z "$SSH_PORT" ]; then
                SSH_PORT=22
            fi
            sudo iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT

            # Save rules
            sudo /sbin/iptables-save

            clear

            if [ "$protocol" == "all" ]; then
            echo "TCP & UDP [$ports] successfully blocked for $isp."
            else
            echo "$protocol [$ports] successfully blocked for $isp."
            fi
            ;;
        2)
            clear

            sudo iptables -A INPUT -s $IP -j DROP

            # ّFind and open SSH port
            SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
            if [ -z "$SSH_PORT" ]; then
                SSH_PORT=22
            fi
            sudo iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT

            # Save rules
            sudo /sbin/iptables-save

            
            clear

            echo "$isp successfully blocked for all ports."
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
    sudo iptables -F
    sudo /sbin/iptables-save
    clear
    echo "$isp UnBlocked successfully!"
    read -p "Press enter to return to Menu" dummy
    blocking_menu
}
# Start the script
main_menu
