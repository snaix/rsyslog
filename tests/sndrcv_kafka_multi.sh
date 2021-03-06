#!/bin/bash
# added 2017-05-08 by alorbach
# This file is part of the rsyslog project, released under ASL 2.0
export TESTMESSAGES=100000
export TESTMESSAGESFULL=100000

# Generate random topic name
export RANDTOPIC=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)

echo ===============================================================================
echo Check and Stop previous instances of kafka/zookeeper 
. $srcdir/diag.sh download-kafka
. $srcdir/diag.sh stop-zookeeper '.dep_wrk1'
. $srcdir/diag.sh stop-zookeeper '.dep_wrk2'
. $srcdir/diag.sh stop-zookeeper '.dep_wrk3'
. $srcdir/diag.sh stop-kafka '.dep_wrk1'
. $srcdir/diag.sh stop-kafka '.dep_wrk2'
. $srcdir/diag.sh stop-kafka '.dep_wrk3'

echo Init Testbench
. $srcdir/diag.sh init

echo Create kafka/zookeeper instance and topics
. $srcdir/diag.sh start-zookeeper '.dep_wrk1'
. $srcdir/diag.sh start-zookeeper '.dep_wrk2'
. $srcdir/diag.sh start-zookeeper '.dep_wrk3'
. $srcdir/diag.sh start-kafka '.dep_wrk1'
. $srcdir/diag.sh start-kafka '.dep_wrk2'
. $srcdir/diag.sh start-kafka '.dep_wrk3'
. $srcdir/diag.sh create-kafka-topic $RANDTOPIC '.dep_wrk1' '22181'

echo Give Kafka some time to process topic create ...
sleep 5

# --- Create omkafka sender config
export RSYSLOG_DEBUGLOG="log"
generate_conf
add_conf '
main_queue(queue.timeoutactioncompletion="60000" queue.timeoutshutdown="60000")

module(load="../plugins/omkafka/.libs/omkafka")
module(load="../plugins/imtcp/.libs/imtcp")
input(type="imtcp" port="'$TCPFLOOD_PORT'" Ruleset="omkafka")	/* this port for tcpflood! */

template(name="outfmt" type="string" string="%msg%\n")

ruleset(name="omkafka") {
	action( type="omkafka"
		name="kafka-fwd"
		broker=["localhost:29092", "localhost:29093", "localhost:29094"]
		topic="'$RANDTOPIC'"
		template="outfmt"
		confParam=[	"compression.codec=none",
				"socket.timeout.ms=5000",
				"socket.keepalive.enable=true",
				"reconnect.backoff.jitter.ms=1000",
				"queue.buffering.max.messages=10000",
				"message.send.max.retries=1"]
		partitions.auto="on"
		partitions.scheme="random"
		resubmitOnFailure="on"
		keepFailedMessages="on"
		failedMsgFile="'$RSYSLOG_OUT_LOG'-failed-'$RANDTOPIC'.data"
		closeTimeout="60000"
		queue.size="1000000"
		queue.type="LinkedList"
		action.repeatedmsgcontainsoriginalmsg="off"
		action.resumeInterval="1"
		action.resumeRetryCount="10"
		action.reportSuspension="on"
		action.reportSuspensionContinuation="on" )
}

'

echo Starting sender instance [omkafka]
startup

# Injection messages now before starting receiver, simply because omkafka will take some time and
# there is no reason to wait for the receiver to startup first. 
tcpflood -m$TESTMESSAGES -i1

# --- Create omkafka receiver config
export RSYSLOG_DEBUGLOG="log2"
generate_conf 2
add_conf '
main_queue(queue.timeoutactioncompletion="60000" queue.timeoutshutdown="60000")

module(load="../plugins/imkafka/.libs/imkafka")
/* Polls messages from kafka server!*/
input(	type="imkafka"
	topic="'$RANDTOPIC'"
	broker=["localhost:29092", "localhost:29093", "localhost:29094"]
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
	action( type="omfile" file=`echo '$RSYSLOG_OUT_LOG'` template="outfmt" )
}
' 2

echo Starting receiver instance [imkafka]
startup 2

echo Stopping sender instance [omkafka]
shutdown_when_empty
wait_shutdown

echo Stopping receiver instance [imkafka]
shutdown_when_empty 2
wait_shutdown 2

echo delete kafka topics
. $srcdir/diag.sh delete-kafka-topic $RANDTOPIC '.dep_wrk1' '22181'

echo stop kafka instances
. $srcdir/diag.sh stop-kafka '.dep_wrk1'
. $srcdir/diag.sh stop-kafka '.dep_wrk2'
. $srcdir/diag.sh stop-kafka '.dep_wrk3'
. $srcdir/diag.sh stop-zookeeper '.dep_wrk1'
. $srcdir/diag.sh stop-zookeeper '.dep_wrk2'
. $srcdir/diag.sh stop-zookeeper '.dep_wrk3'

# Do the final sequence check
seq_check 1 $TESTMESSAGESFULL -d

echo success
exit_test