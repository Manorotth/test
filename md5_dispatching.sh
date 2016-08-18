#!/bin/bash

INPUT=/home/mbourguignon/delivery/$1
LISTED_MD5=$(cat $INPUT | awk '{print $3}') 
SCRIPT=$(basename -- "$0")

WORK_DIR=/home/mbourguignon/temp_dir/$SCRIPT/
if ! test -d $WORK_DIR; then
	mkdir -p $WORK_DIR
fi
OUTPUT=$WORK_DIR/output

rm -rf $WORK_DIR/*


##FOR EACH LISTED MD5 IN A "DELIVERY" FILE CHECK IF PRESENT ON BUFFER AND IF YES WICH ONE
for md5 in $LISTED_MD5; 
do
	((count_md5++))

	for buffer in buffer-1 buffer-2 buffer-3 buffer-4 buffer-5 
	do
		spotted=$(ssh -o stricthostkeychecking='no' $buffer 'test -d /mnt/space/agent/cache/'$md5' && echo yes || echo no')
		if [ "$spotted" = "yes" ] 
		then
			echo $md5 spotted on $buffer
			echo $md5 >> $WORK_DIR/$buffer.md5s
			break
		else
			echo $md5 has not been spotted on $buffer	
			echo $md5 >> $WORK_DIR/missing_md5s
		#elif [ "$spotted" != "0" ]
		#then
		#	echo "md5 hasn't been spotted on $buffer"
		#	echo "value : "$spotted " | buffer: "$buffer" | md5 : " $md5 
		fi
	done
done

echo "Total md5 count in input file  " $count_md5 >> $OUTPUT

##FILES DETECTED ON BUFFER
for i in $(ls $WORK_DIR | grep buffer | grep -v missing)
do
	value_counted=$(cat $WORK_DIR/$i | wc -l)
	echo $i count : $(cat $WORK_DIR/$i | wc -l) >> $OUTPUT
    total_count_addition=$value_counted
    total_count=$(echo  $(( $total_count + $total_count_addition | bc )))
done

##FILES NOT DETECTED ON BUFFER

	number_of_missing=$(cat $WORK_DIR/missing_md5s | wc -l) 
	echo "number of missing files :"
	echo $number_of_missing >> $OUTPUT
	echo "Missing files :"
    cat $WORK_DIR/missing_md5s | sort | uniq >> $OUTPUT

    #value_counted_missing=$(cat $WORK_DIR/$i | wc -l)
    #echo $i count missings : $(cat $WORK_DIR/$i | sort | uniq | wc -l) >> $OUTPUT
    #total_count_addition_missing=$value_counted_missing
    #total_count_missing=$(echo  $(( $total_count_missing + $total_count_addition_missing | bc )))


echo "Total missing md5 counted by script :  " $total_count_missing >> $OUTPUT
echo "Total md5 counted by script :  " $total_count >> $OUTPUT
cat $OUTPUT
