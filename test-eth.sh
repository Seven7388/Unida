ETH=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
echo $ETH
