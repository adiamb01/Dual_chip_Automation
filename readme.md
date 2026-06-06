Pre requisites - 
1) CESW CPU+CMN PMU latest driver should be installed
2) perf list command should show all the events. If it doesnt then link the perf binary to /usr/bin/perf. Compiled perf binary is released in same location where Tool is released. 
3) Install python libraries
sudo apt-get update
sudo apt-get install -y python3-pip
sudo python3 -m pip install openpyxl --break-system-packages

Getting the stats - 
1) Launch the workload and make sure all the threads are spawned 
2) Once the WL is running execute the tool using following command
./SE_Perf_Dual_Chip_Bandwidth_Automation.sh <sampling duration in seconds> <locaiton where you want to save the output>
- DefaultLogs are saved in same loc where the shell script is
3) At the end of the execution of the tool it will print the top level KPIs in the prompt itself.
4) Detailed logs per nodeid can be found in parsed_perf_stats.xlsx
5) Entire Raw dump is available in raw_perf_stats.txt
6) All of the above files can be pulled out in case of CESW through scp
7) In case you lose parsed_perf_stats.xlsx but have raw_perf_stats.txt it can be parsed using 
./SE_Perf_Dual_Chip_Bandwidth_Automation.sh --parse-only raw_perf_stats.txt
