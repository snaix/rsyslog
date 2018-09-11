#!/bin/bash
# added 2017-06-06 by alorbach
#	This tests the keepFailedMessages feature in omkafka
# This file is part of the rsyslog project, released under ASL 2.0
export TESTMESSAGES=50000
export TESTMESSAGESFULL=50000

# Generate random topic name
export RANDTOPIC=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)

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
. $srcdir/diag.sh create-kafka-topic $RANDTOPIC '.dep_wrk' '22181'

echo Give Kafka some time to process topic create ...
sleep 5

# --- Create omkafka receiver config
export RSYSLOG_DEBUGLOG="log"
generate_conf
add_conf '
module(load="../plugins/imkafka/.libs/imkafka")
/* Polls messages from kafka server!*/
input(	type="imkafka"
	topic="'$RANDTOPIC'"
	broker="localhost:29092"
	consumergroup="default"
	confParam=[ "compression.codec=none",
		"session.timeout.ms=10000",
		"socket.timeout.ms=5000",
		"socket.keepalive.enable=true",
		"reconnect.backoff.jitter.ms=1000",
		"enable.partition.eof=false" ]
	)

template(name="outfmt" type="string" string="%msg:F,58:2%\n")

if ($msg contains "msgnum:") then {
	action( type="omfile" file=`echo $RSYSLOG_OUT_LOG` template="outfmt" )
}
'

echo Starting receiver instance [omkafka]
startup
# ---

# --- Create omkafka sender config
export RSYSLOG_DEBUGLOG="log2"
generate_conf 2
add_conf '
main_queue(queue.timeoutactioncompletion="10000" queue.timeoutshutdown="60000")

module(load="../plugins/omkafka/.libs/omkafka")
module(load="../plugins/imtcp/.libs/imtcp")
input(type="imtcp" port="'$TCPFLOOD_PORT'")	/* this port for tcpflood! */

template(name="outfmt" type="string" string="%msg%\n")

action(	name="kafka-fwd"
	type="omkafka"
	topic="'$RANDTOPIC'"
	broker="localhost:29092"
	template="outfmt"
	confParam=[	"compression.codec=none",
			"socket.timeout.ms=5000",
			"socket.keepalive.enable=true",
			"reconnect.backoff.jitter.ms=1000",
			"queue.buffering.max.messages=20000",
			"message.send.max.retries=1"]
	topicConfParam=["message.timeout.ms=5000"]
	partitions.auto="on"
	resubmitOnFailure="on"
	keepFailedMessages="on"
	failedMsgFile="'$RSYSLOG_OUT_LOG'-failed-'$RANDTOPIC'.data"
	action.resumeInterval="1"
	action.resumeRetryCount="10"
	queue.saveonshutdown="on"
	)
' 2

echo Starting sender instance [imkafka]
startup 2
# ---

echo Inject messages into rsyslog sender instance
tcpflood -m$TESTMESSAGES -i1

echo Stopping kafka cluster instance
. $srcdir/diag.sh stop-kafka

echo Stopping sender instance [imkafka]
shutdown_when_empty 2
wait_shutdown 2

echo Starting kafka cluster instance
. $srcdir/diag.sh start-kafka

echo Sleep to give rsyslog instances time to process data ...
sleep 5

echo Starting sender instance [imkafka]
export RSYSLOG_DEBUGLOG="log3"
startup 2

echo Sleep to give rsyslog sender time to send data ...
sleep 5

echo Stopping sender instance [imkafka]
shutdown_when_empty 2
wait_shutdown 2

echo Stopping receiver instance [omkafka]
shutdown_when_empty
wait_shutdown

echo delete kafka topics
. $srcdir/diag.sh delete-kafka-topic 'static' '.dep_wrk' '22181'

echo stop kafka instance
. $srcdir/diag.sh stop-kafka

# STOP ZOOKEEPER in any case
. $srcdir/diag.sh stop-zookeeper

# Do the final sequence check
seq_check 1 $TESTMESSAGESFULL

echo success
exit_test