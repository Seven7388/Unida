with open("unida-installer.sh", "r") as f:
    content = f.read()

old_str = """        echo "================="
    else
        echo "[-] Failed to download update."
    fi
    pause
}"""

new_str = """        echo "================="
        echo ""
        echo "[!] Restarting CLI to apply updates..."
        sleep 2
        exec unida
    else
        echo "[-] Failed to download update."
        pause
    fi
}"""

content = content.replace(old_str, new_str)

with open("unida-installer.sh", "w") as f:
    f.write(content)
