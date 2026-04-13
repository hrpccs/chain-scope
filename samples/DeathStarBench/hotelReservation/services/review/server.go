package review

import (
	"encoding/json"
	"fmt"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"

	// "io/ioutil"
	"net"
	// "os"
	// "sort"
	"time"
	//"sync"

	"github.com/rs/zerolog/log"

	"github.com/delimitrou/DeathStarBench/tree/master/hotelReservation/registry"
	pb "github.com/delimitrou/DeathStarBench/tree/master/hotelReservation/services/review/proto"
	"github.com/delimitrou/DeathStarBench/tree/master/hotelReservation/tls"
	"github.com/google/uuid"
	"github.com/opentracing/opentracing-go"
	"golang.org/x/net/context"
	"google.golang.org/grpc"
	"google.golang.org/grpc/keepalive"

	// "strings"

	"github.com/bradfitz/gomemcache/memcache"
)

const name = "srv-review"

// Server implements the rate service
type Server struct {
	pb.UnimplementedReviewServer

	Tracer      opentracing.Tracer
	Port        int
	IpAddr      string
	MongoClient *mongo.Client
	Registry    *registry.Client
	MemcClient  *memcache.Client
	uuid        string
}

// Run starts the server
func (s *Server) Run() error {
	opentracing.SetGlobalTracer(s.Tracer)

	if s.Port == 0 {
		return fmt.Errorf("server port must be set")
	}

	s.uuid = uuid.New().String()

	opts := []grpc.ServerOption{
		grpc.KeepaliveParams(keepalive.ServerParameters{
			Timeout: 120 * time.Second,
		}),
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			PermitWithoutStream: true,
		}),

		grpc.NumStreamWorkers(0), // Set the number of stream workers to handle incoming streams
	}

	if tlsopt := tls.GetServerOpt(); tlsopt != nil {
		opts = append(opts, tlsopt)
	}

	srv := grpc.NewServer(opts...)

	pb.RegisterReviewServer(srv, s)

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", s.Port))
	if err != nil {
		log.Fatal().Msgf("failed to listen: %v", err)
	}

	err = s.Registry.Register(name, s.uuid, s.IpAddr, s.Port)
	if err != nil {
		return fmt.Errorf("failed register: %v", err)
	}
	log.Info().Msg("Successfully registered in consul")

	return srv.Serve(lis)
}

// Shutdown cleans up any processes
func (s *Server) Shutdown() {
	s.Registry.Deregister(s.uuid)
}

type ReviewHelper struct {
	ReviewId    string    `bson:"reviewId"`
	HotelId     string    `bson:"hotelId"`
	Name        string    `bson:"name"`
	Rating      float32   `bson:"rating"`
	Description string    `bson:"description"`
	Image       *pb.Image `bson:"images"`
}

type ImageHelper struct {
	Url     string `bson:"url"`
	Default bool   `bson:"default"`
}

func (s *Server) GetReviews(ctx context.Context, req *pb.Request) (*pb.Result, error) {

	res := new(pb.Result)
	reviews := make([]*pb.ReviewComm, 0)

	hotelId := req.HotelId

	item, err := s.MemcClient.Get(hotelId)
	if err != nil && err != memcache.ErrCacheMiss {
		log.Panic().Msgf("Tried to get hotelId [%v], but got memmcached error = %s", hotelId, err)
	} else {
		if err == memcache.ErrCacheMiss {

			//session := s.MongoSession.Copy()
			//defer session.Close()
			//c := session.DB("review-db").C("reviews")
			c := s.MongoClient.Database("review-db").Collection("reviews")

			curr, err := c.Find(context.TODO(), bson.M{"hotelId": hotelId})
			if err != nil {
				log.Error().Msgf("Failed get reviews: ", err)
			}

			var reviewHelpers []ReviewHelper
			//err = c.Find(bson.M{"hotelId": hotelId}).All(&reviewHelpers)
			curr.All(context.TODO(), &reviewHelpers)
			if err != nil {
				log.Error().Msgf("Failed get hotels data: ", err)
			}

			for _, reviewHelper := range reviewHelpers {
				revComm := pb.ReviewComm{
					ReviewId:    reviewHelper.ReviewId,
					Name:        reviewHelper.Name,
					Rating:      reviewHelper.Rating,
					Description: reviewHelper.Description,
					Images:      reviewHelper.Image}
				reviews = append(reviews, &revComm)
			}

			reviewJson, err := json.Marshal(reviews)
			if err != nil {
				log.Error().Msgf("Failed to marshal hotel [id: %v] with err:", hotelId, err)
			}
			memcStr := string(reviewJson)

			s.MemcClient.Set(&memcache.Item{Key: hotelId, Value: []byte(memcStr)})
		} else {
			reviewsStr := string(item.Value)
			log.Trace().Msgf("memc hit with %v", reviewsStr)
			if err := json.Unmarshal([]byte(reviewsStr), &reviews); err != nil {
				log.Panic().Msgf("Failed to unmarshal reviews: %s", err)
			}
		}
	}

	//reviewsEmpty := make([]*pb.ReviewComm, 0)

	res.Reviews = reviews
	return res, nil
}
