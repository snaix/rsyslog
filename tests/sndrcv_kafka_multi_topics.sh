#!/bin/bash
# added 2018-08-13 by alorbach
# This file is part of the rsyslog project, released under ASL 2.0
export TESTMESSAGES=50000
export TESTMESSAGESFULL=100000

# Generate random topic name
export RANDTOPIC1=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
export RANDTOPIC2=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)

# enable the EXTRA_EXITCHECK only if really needed - otherwise spams the test log
# too much
#export EXTRA_EXITCHECK=dumpkafkalogs
echo ===============================================================================
echo Check and Stop previous instances of kafka/zookeeper 
. $srcdir/diag.sh download-kafka
. $srcdir/diag.sh stop-zookeeper
. $srcdir/diag.sh stop-kafka

echo Init Testbench
. $srcdir/diag.sh init

echo Create kafka/zookeeper instance and topics
. $srcdir/diag.sh start-zookeeper
. $srcdir/diag.sh start-kafka
. $srcdir/diag.sh create-kafka-topic $RANDTOPIC1 '.dep_wrk' '22181'
. $srcdir/diag.sh create-kafka-topic $RANDTOPIC2 '.dep_wrk' '22181'

echo Give Kafka some time to process topic create ...
sleep 5

# --- Create omkafka sender config
export RSYSLOG_DEBUGLOG="log"
generate_conf
add_conf '
main_queue(queue.timeoutactioncompletion="60000" queue.timeoutshutdown="60000")

module(load="../plugins/omkafka/.libs/omkafka")
module(load="../plugins/imtcp/.libs/imtcp")
input(type="imtcp" port="'$TCPFLOOD_PORT'")	/* this port for tcpflood! */

template(name="outfmt" type="string" string="%msg%\n")

local4.* action(	name="kafka-fwd"
	type="omkafka"
	topic="'$RANDTOPIC1'"
	broker="localhost:29092"
	template="outfmt"
	confParam=[	"compression.codec=none",
			"socket.timeout.ms=10000",
			"socket.keepalive.enable=true",
			"reconnect.backoff.jitter.ms=1000",
			"queue.buffering.max.messages=10000",
			"enable.auto.commit=true",
			"message.send.max.retries=1"]
	topicConfParam=["message.timeout.ms=10000"]
	partitions.auto="on"
	closeTimeout="60000"
	resubmitOnFailure="on"
	keepFailedMessages="on"
	failedMsgFile="'$RSYSLOG_OUT_LOG'-failed-'$RANDTOPIC1'.data"
	action.resumeInterval="1"
	action.resumeRetryCount="10"
	queue.saveonshutdown="on"
	)
local4.* action(	name="kafka-fwd"
	type="omkafka"
	topic="'$RANDTOPIC2'"
	broker="localhost:29092"
	template="outfmt"
	confParam=[	"compression.codec=none",
			"socket.timeout.ms=10000",
			"socket.keepalive.enable=true",
			"reconnect.backoff.jitter.ms=1000",
			"queue.buffering.max.messages=10000",
			"enable.auto.commit=true",
			"message.send.max.retries=1"]
	topicConfParam=["message.timeout.ms=10000"]
	partitions.auto="on"
	closeTimeout="60000"
	resubmitOnFailure="on"
	keepFailedMessages="on"
	failedMsgFile="'$RSYSLOG_OUT_LOG'-failed-'$RANDTOPIC2'.data"
	action.resumeInterval="1"
	action.resumeRetryCount="10"
	queue.saveonshutdown="on"
	)
'

echo Starting sender instance [omkafka]
startup
# ---

# Injection messages now before starting receiver, simply because omkafka will take some time and
# there is no reason to wait for the receiver to startup first. 
echo Inject messages into rsyslog sender instance
tcpflood -m$TESTMESSAGES -i1

# --- Create omkafka receiver config
export RSYSLOG_DEBUGLOG="log2"
generate_conf 2
add_conf '
main_queue(queue.timeoutactioncompletion="60000" queue.timeoutshutdown="60000")

module(load="../plugins/imkafka/.libs/imkafka")
/* Polls messages from kafka server!*/
input(	type="imkafka"
	topic="'$RANDTOPIC1'"
	broker="localhost:29092"
	consumergroup="default1"
	confParam=[ "compression.codec=none",
		"session.timeout.ms=10000",
		"socket.timeout.ms=10000",
		"enable.partition.eof=false",
		"reconnect.backoff.jitter.ms=1000",
		"socket.keepalive.enable=true"]
	)
input(	type="imkafka"
	topic="'$RANDTOPIC2'"
	broker="localhost:29092"
	consumergroup="default2"
	confParam=[ "compression.codec=none",
		"session.timeout.ms=10000",
		"socket.timeout.ms=10000",
		"enable.partition.eof=false",
		"reconnect.backoff.jitter.ms=1000",
		"socket.keepalive.enable=true"]
	)

template(name="outfmt" type="string" string="%msg:F,58:2%\n")

if ($msg contains "msgnum:") then {
	action( type="omfile" file=`echo $RSYSLOG_OUT_LOG` template="outfmt" )
}
' 2

echo Starting receiver instance [imkafka]
startup 2
# ---

echo Stopping sender  instance [omkafka]
shutdown_when_empty
wait_shutdown

echo Stopping receiver instance [imkafka]
shutdown_when_empty 2
wait_shutdown 2

echo delete kafka topics
. $srcdir/diag.sh delete-kafka-topic $RANDTOPIC1 '.dep_wrk' '22181'
. $srcdir/diag.sh delete-kafka-topic $RANDTOPIC2 '.dep_wrk' '22181'

# Dump Kafka log | uncomment if needed
# . $srcdir/diag.sh dump-kafka-serverlog

echo stop kafka instance
. $srcdir/diag.sh stop-kafka

# STOP ZOOKEEPER in any case
. $srcdir/diag.sh stop-zookeeper

# Do the final sequence check
seq_check 1 $TESTMESSAGES -d

linecount=$(wc -l < ${RSYSLOG_OUT_LOG})
if [ $linecount -ge $TESTMESSAGESFULL ]; then
	echo "Info: Count correct: $linecount"
else
	echo "Count error detected in $RSYSLOG_OUT_LOG"
	echo "number of lines in file: $linecount"
	error_exit 1 
fi

echo success
exit_test